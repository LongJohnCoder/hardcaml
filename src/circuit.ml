(* A circuit is defined by transitively following the dependencies of its outputs,
   stopping at unassigned wires or constants.  [Signal_graph.inputs] does this.
   All such unassigned wires are circuit inputs.  As a consequence, all other wires
   in a circuit are assigned, and hence cannot be changed. *)

open! Import

module Uid_map = Signal.Uid_map
module Uid_set = Signal.Uid_set

module Signal_map = struct
  type t = Signal.t Uid_map.t [@@deriving sexp_of]

  let create graph =
    let add_signal map signal =
      let uid = Signal.uid signal in
      Map.add_exn map ~key:uid ~data:signal
    in
    Signal_graph.depth_first_search graph ~init:Uid_map.empty ~f_before:add_signal
end

type t =
  { name          : string
  ; signal_by_uid : Signal_map.t
  ; inputs        : Signal.t list
  ; outputs       : Signal.t list
  ; phantom_inputs : (string * int) list
  ; signal_graph  : Signal_graph.t
  (* [fan_in] and [fan_out] are lazily computed.  One might worry that this would interact
     poorly with signals, which have some mutable components (e.g. wires).  But those have
     already been set by the time a circuit is created, so a circuit is not mutable. *)
  ; fan_out       : Signal.Uid_set.t Signal.Uid_map.t Lazy.t
  ; fan_in        : Signal.Uid_set.t Signal.Uid_map.t Lazy.t }
[@@deriving fields, sexp_of]

type 'a with_create_options
  =  ?detect_combinational_loops : bool
  -> ?normalize_uids : bool
  -> 'a

module Create_options = struct
  type t =
    { detect_combinational_loops : bool option
    ; normalize_uids             : bool option }
  [@@deriving sexp_of]
end

let with_create_options f ?detect_combinational_loops ?normalize_uids =
  f { Create_options.detect_combinational_loops; normalize_uids }

let call_with_create_options t
      { Create_options. detect_combinational_loops; normalize_uids } =
  t ?detect_combinational_loops ?normalize_uids

let create_exn
      ?(detect_combinational_loops = true)
      ?(normalize_uids = true)
      ~name outputs =
  let signal_graph = Signal_graph.create outputs in
  (* check that all outputs are assigned wires with 1 name *)
  ignore (ok_exn (Signal_graph.outputs ~validate:true signal_graph) : Signal.t list);
  (* uid normalization *)
  let signal_graph =
    if normalize_uids
    then Signal_graph.normalize_uids signal_graph
    else signal_graph
  in
  (* get new output wires *)
  let outputs = Signal_graph.outputs signal_graph |> ok_exn in
  (* get inputs checking that they are valid *)
  let inputs = ok_exn (Signal_graph.inputs signal_graph) in
  (* check for combinational loops *)
  if detect_combinational_loops
  then ok_exn (Signal_graph.detect_combinational_loops signal_graph);
  (* construct the circuit *)
  { name           = name
  ; signal_by_uid  = Signal_map.create signal_graph
  ; inputs
  ; outputs
  ; phantom_inputs = []
  ; signal_graph
  ; fan_out        = lazy (Signal_graph.fan_out_map signal_graph)
  ; fan_in         = lazy (Signal_graph.fan_in_map  signal_graph) }

let set_phantom_inputs circuit phantom_inputs =
  (* Remove phantom inputs that are already inputs, and disallow phantom inputs
     that have the same name as an output. *)
  let module Port = struct
    module T = struct
      type t = string * int[@@deriving sexp_of]
      let compare (n0,_) (n1,_) = String.compare n0 n1
    end
    include T
    include Comparable.Make(T)
    let of_signal port =
      let name =
        match Signal.names port with
        | name :: [] -> name
        | _ -> raise_s [%message "Ports should have one name" (port : Signal.t)]
      in
      name, Signal.width port
  end in
  let inputs = List.map circuit.inputs ~f:Port.of_signal |> Set.of_list (module Port) in
  let outputs = List.map circuit.outputs ~f:Port.of_signal |> Set.of_list (module Port) in
  let phantom = Set.of_list (module Port) phantom_inputs in
  let phantom_inputs = Set.diff phantom inputs in
  if not (Set.is_empty (Set.inter phantom_inputs outputs))
  then raise_s [%message "Phantom input is also a circuit output"
                           (phantom_inputs : Set.M(Port).t)
                           (outputs : Set.M(Port).t)];
  { circuit with phantom_inputs = phantom_inputs |> Set.to_list }

let with_name t ~name = { t with name }

let uid_equal a b = Int64.equal (Signal.uid a) (Signal.uid b)

let is_input  t signal = List.mem t.inputs  signal ~equal:uid_equal
let is_output t signal = List.mem t.outputs signal ~equal:uid_equal

let find_signal_exn t uid = Map.find_exn t.signal_by_uid uid

let fan_out_map t = Lazy.force t.fan_out
let fan_in_map  t = Lazy.force t.fan_in

let signal_map c = c.signal_by_uid

let structural_compare ?check_names c0 c1 =
  try
    (* outputs, including names, are the same *)
    List.fold2_exn (outputs c0) (outputs c1) ~init:true ~f:(fun b o0 o1 ->
      b
      && [%compare.equal: string list] (Signal.names o0) (Signal.names o1)
      && Signal.width o0 = Signal.width o1)
    &&
    (* inputs, including names, are the same *)
    List.fold2_exn (inputs c0) (inputs c1) ~init:true ~f:(fun b i0 i1 ->
      b
      &&  [%compare.equal: string list] (Signal.names i0) (Signal.names i1)
      && Signal.width i0 = Signal.width i1)
    &&
    (* check full structural comparision from each output *)
    List.fold2_exn (outputs c0) (outputs c1) ~init:true ~f:(fun b s t ->
      b && (Signal.structural_compare ?check_names s t))
  with Not_found_s _ | Caml.Not_found ->
    false

module Port_checks = struct
  type t =
    | Relaxed
    | Port_sets
    | Port_sets_and_widths
end

module With_interface (I : Interface.S) (O : Interface.S) = struct
  type create = Signal.t Interface.Create_fn(I)(O).t

  let check_io_port_sets_match circuit =
    let actual_ports ports =
      List.map ports ~f:Signal.names
      |> List.concat
      |> Set.of_list (module String)
    in
    let actual_input_ports = inputs circuit |> actual_ports in
    let actual_input_ports =
      phantom_inputs circuit |> List.map ~f:fst |> Set.of_list (module String)
      |> Set.union actual_input_ports
    in
    let actual_output_ports = outputs circuit |> actual_ports in
    let expected_input_ports = I.port_names |> I.to_list |> Set.of_list (module String) in
    let expected_output_ports = O.port_names |> O.to_list |> Set.of_list (module String) in

    let check direction actual_ports expected_ports =
      let expected_but_not_in_circuit = Set.diff expected_ports actual_ports in
      let in_circuit_but_not_expected = Set.diff actual_ports expected_ports in
      if not (Set.is_empty expected_but_not_in_circuit)
      || not (Set.is_empty in_circuit_but_not_expected)
      then raise_s [%message "Port sets do not match"
                               (direction : string)
                               (expected_ports : Set.M(String).t)
                               (actual_ports : Set.M(String).t)
                               (expected_but_not_in_circuit : Set.M(String).t)
                               (in_circuit_but_not_expected : Set.M(String).t)]
    in
    check "input" actual_input_ports expected_input_ports;
    check "output" actual_output_ports expected_output_ports

  let check_widths_match circuit =
    let port s =
      match Signal.names s with
      | [name] -> name, Signal.width s
      | _ ->
        raise_s
          [%message
            "[Circuit.With_interface.check_widths_match] Unexpected error - invalid port name(s)"
              (circuit : t)]
    in
    let inputs = inputs circuit |> List.map ~f:port |> I.of_alist in
    let outputs = outputs circuit |> List.map ~f:port |> O.of_alist in
    if not (I.equal Int.equal inputs I.port_widths)
    then raise_s [%message "Input port widths do not match"
                             ~expected:(I.port_widths : int I.t)
                             ~got:(inputs : int I.t)];
    if not (O.equal Int.equal outputs O.port_widths)
    then raise_s [%message "Output port widths do not match"
                             ~expected:(O.port_widths : int O.t)
                             ~got:(outputs : int O.t)]

  let check_io_port_sets_and_widths_match circuit =
    check_io_port_sets_match circuit;
    check_widths_match circuit

  let create_exn =
    with_create_options
      (fun create_options ?(port_checks=Port_checks.Relaxed) ?(add_phantom_inputs=true)
        ~name logic ->
        let outputs = logic (I.map I.t ~f:(fun (n, b) -> Signal.input n b)) in
        let circuit =
          call_with_create_options
            create_exn create_options ~name
            (O.to_list (O.map2 O.t outputs ~f:(fun (n, _) s -> Signal.output n s)))
        in
        let circuit =
          if add_phantom_inputs
          then set_phantom_inputs circuit (I.to_list I.t)
          else circuit
        in
        (match port_checks with
         | Relaxed -> ()
         | Port_sets -> check_io_port_sets_match circuit
         | Port_sets_and_widths -> check_io_port_sets_and_widths_match circuit); circuit)
end
