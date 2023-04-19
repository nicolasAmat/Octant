open Net
    

(* A marking is a mutable buffer to hold a (positive) marking vector. *)
type marking

type t = marking

(* safe: safe net, places are bounded by 1 *)
val init: ?safe:bool -> net -> marking

val clone: t -> t

(* @noalloc *)
val get: t -> pl_id -> int

(* add m pl x  returns m, modified,  or a new marking.
 *
 * Beware, it looks like a pure function, but it is not.
 *
 * @noalloc most of the time.
 * @alloc if the array needs to be reformated (overflows the current format). See Intarray. *)
val add: t -> pl_id -> int -> t

(* @noalloc *)
val compare: t -> t -> int

val tos: ?max:int -> t -> string
