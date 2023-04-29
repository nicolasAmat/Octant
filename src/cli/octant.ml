open Petrinet
open Parsers
open Logic
open Libtfg
open Term2
open Parse
open Projector

(* Default timeout for walkers, in s. *)
let default_timeout = 10

let default_project_timeout = 3600

type bundle =
  { net: Net.t ;
    marking: Marking.t ;
    tfg: Tfg.t option }

type form =
  | Formula of Formula.t
  | Projected of projected_goal

type element =
  | Bundle of bundle
  | Forms of form list

(* Global environment: maps ids to elements. *)
type env =
  { map: (string * element) list ;

    (* Print formulas in smt-lib format. *)
    smt_format: bool ;
    
    time: float option ;
    verb: bool }

let add_env name elt env = { env with map = (name, elt) :: env.map }

let init_env = { map = [] ; verb = true ; time = None ; smt_format = false }

let comma s x = if s = "" then x else s ^ ", " ^ x

let form2goal = function
  | Formula g -> g
  | Projected pg -> pg.p_goal

module St = Stackcl.Mk
    (struct
      type elt = element
      type info = env

      let elt2s = function
        | Forms l -> let n = List.length l in Styled.(b lgray (if n = 1 then "a formula" else "a list of " ^ string_of_int n ^ " formulas") e)
                         
        | Bundle b ->
          let extra = if Net.is_safe b.net then "safe" else "" in
          let extra = if b.tfg = None then extra else comma extra "tfg" in
          let extra = if extra = "" then "" else "(" ^ extra ^ ")" in
          Styled.(b lgray ("bundle" ^ extra) e)
    end)

open St

let cl_string x = Ok x

let cl_int x = match int_of_string_opt x with Some i -> Ok i | None -> Failed "Not an int."

let cl_filename x = if Sys.file_exists x then Ok x else Failed "This is not a file."

let cl_env_name env x = if List.mem_assoc x env.map then Ok x else Failed "Not bound in the environment."

let id d = d

let ids x = Ok x

let bind env name elt = ((), add_env name elt env)
let set = bind

let get_bundle env =
  let rec loop = function
    | [] -> failwith "No bundle in current environment."
    | (_, Forms _) :: rest -> loop rest
    | (name, Bundle b) :: _ -> (name, b)
  in
  loop env.map

let load env filename =

  (* Read net *)
  let%lwt (net, marking) = Parse.read_net_places filename
  in

  (* Read may-be-here TFG *)
  let%lwt tfg =
    try%lwt
      let%lwt tfg = Parse.read_tfg net filename in
      
      if Tfg.is_empty tfg then Lwt.return_none
      else Lwt.return (Some tfg)
          
    with _ -> Lwt.return_none
  in
  
  let bundle = Bundle { net ; marking ; tfg } in    
  Lwt.return (bind env "net" bundle)

let get_pl_reader env =
  let (_,b) = get_bundle env in
  match b.tfg with
  | None -> Net.get_plnamebrace b.net
  | Some tfg -> Tfg.get_nodenamebrace tfg

let form2s env f =

  let reader = get_pl_reader env in

  let g2s = Printformula.(if env.smt_format then goal2smt else goal2s) in
  
  match f with
  | Formula f -> g2s reader f
  | Projected pg -> g2s reader pg.p_goal ^ (if pg.complete then " # complete" else " # uncomplete") ^ Printf.sprintf " (%d / %d)" pg.n_complete_cubes pg.n_cubes


let get env name =
  try List.assoc name env.map
  with Not_found -> failwith (name ^ " is not defined in the environment.")

let get_source env =
  let (_,b) = get_bundle env in
  match b.tfg with
  | None -> Net b.net
  | Some tfg -> Tfg tfg

let get_tfg env = match get_source env with
  | Tfg tfg -> tfg
  | Net _ -> failwith "This bundle has no tfg."  

let mkform l = Forms (List.map (fun f -> Formula f) l)
let mkproj l = Forms (List.map (fun f -> Projected f) l)

let get_forms = function
  | Forms l -> Ok l
  | _ -> Failed "Not a list of formulas"

let read_forms env f = Parse.sread_goals (get_source env) f
let load_forms env f = Parse.read_goals (get_source env) f

let project timeout env l =
  let tfg = get_tfg env in
  
  Common.mymap l
    begin function
      | Formula f -> Projector.project ~timeout tfg f
      | Projected _ -> failwith "Cannot project a formula that is already projected."
    end

let fprint env elt = match elt with
  | Bundle _ -> Term2.fprints (elt2s elt)
  | Forms l ->
    let forms = Common.sep (form2s env) "\n" l in
    Lwt_io.printf "%s\n" forms 

let nl _ = Styled.(p cyan "\n###########################################\n\n" e)

let to_quiet env = ((), { env with verb = false })

let to_smt env = ((), { env with smt_format = true })

let do_time env =

  let now = Unix.gettimeofday () in
  
  let%lwt () = match env.time with
    | None -> Lwt.return_unit
    | Some start -> Styled.(p fmt orange "# Time: %.2f s\n" (now -. start) e)
  in

  Lwt.return ((), { env with time = Some now })


 
let machine =
  [

    info ("Additionally, a global environment consists in bindings of the form\n\n" ^
          "    name => formula\n" ^
          "    name => bundle (that is: a Petri net, an initial marking, and possibly a tfg).") ;
    
    title "Environment" ;

    def "load" implicit get_info !=> cl_filename nop !=%+ load
      "Load the given Petri net, put it as a bundle in the environment with the name 'net'. E.g.: load \"file.net\"." ;

    def "bind" get_info !=> cl_string !-> ids nop !==+ bind "Binds the element on the stack to the given name. E.g.: bind special-net." ;
    def "set"  get_info !=> cl_string !-> ids nop !==+ bind "Synonym to bind." ;

    def "get" implicit get_info !==> cl_env_name !-> id !== get "Gets the element associated to the given identifier in the environment. Pushes it. E.g.: get special-net." ;
    
    title "Formulas" ;

    def "form" get_info !=> cl_string !-> mkform !=% read_forms            "Parse and push the given formula(s) on the stack (as a list). The reference bundle is the last found in the environment." ;
    def "load-forms" get_info !=> cl_string !-> mkform !=% load_forms      "Read formulas from the given file and push them on the stack (as a list). The reference bundle is the last found in the environment." ;

    def "project"             get_info  !-> get_forms !-> mkproj !== (project default_project_timeout) "Projects a list of formulas (popped from the stack). The reference bundle must have a tfg. Pushes the resulting list of formulas." ;
    def "tproject" !=> cl_int get_info  !-> get_forms !-> mkproj !== project                           "Projects with a time limit." ;
    
    title "Display" ;

    def "quiet"      get_info nop !==+ to_quiet "Quiet mode (prints only necessary information, e.g. verdicts)." ;
    def "smt-format" get_info nop !==+ to_smt   "Use smt-lib format when printing formulas." ;
      
    print () ;
    def "fprint" get_info !-> ids nop !=% fprint "Full print: print the topmost stack element, with details." ;
    def "nl" get_info nop !=% nl "Prints a blank line (separator)." ;

    title "Others" ;

    def "time" get_info nop !=%+ do_time "Prints the delay since the previous time command. The first time command does not print anything." ;
    dup () ;
    pop () ;
    help () ;
  ]


let run () =
  try%lwt
    let%lwt _ = St.exec machine Sys.argv init_env () in 
    Lwt.return_unit
  with Stackcl.Error msg ->
    Term2.Styled.(p
              nl
              red msg
              nl nl
              e)

open Lwtlaunch.Setkeys
let () = noconfig ===> Lwtlaunch.launch ~appname:"octant" ~run ()
