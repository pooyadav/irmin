(*
 * Copyright (c) 2013-2014 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Core_kernel.Std
open IrminSig
open Lwt
open IrminMerge.OP

module Log = Log.Make(struct let section = "BRANCH" end)

module type S = sig
  include RW
  type branch
  val create: ?branch:branch -> unit -> t Lwt.t
  val current_branch: t -> branch Lwt.t
  val update: t -> ?origin:origin -> key -> value -> unit Lwt.t
  val remove: t -> ?origin:origin -> key -> unit Lwt.t
  val clone: t -> branch -> t option Lwt.t
  val clone_force: t -> branch -> t Lwt.t
  val merge: t -> ?origin:origin -> branch -> unit IrminMerge.result Lwt.t
  val merge_exn: t -> ?origin:origin -> branch -> unit Lwt.t
end

module type STORE = sig
  module Block: IrminBlock.STORE
  module Tag: IrminTag.STORE with type value = Block.key
  include S with type key = IrminPath.t
             and type branch = Tag.key
             and type value = Block.contents
  val block_t: t -> Block.t
  val contents_t: t -> Block.Contents.t
  val node_t: t -> Block.Node.t
  val commit_t: t -> Block.Commit.t
  val tag_t: t -> Tag.t
  val map_head_node: t -> key -> f:(Block.Node.t -> Block.node -> key -> 'a Lwt.t) -> 'a Lwt.t
  val update_head_node: t -> origin:origin -> f:(Block.node -> Block.node Lwt.t) -> unit Lwt.t
  val merge_commit: t -> ?origin:origin -> Block.key -> unit IrminMerge.result Lwt.t
  val watch_nodes: t -> key -> (key * Block.key) Lwt_stream.t
  module Key: IrminKey.S with type t = key
  module Value: IrminContents.S with type t = value
  module Graph: IrminGraph.S with type V.t = (Block.key, Tag.key) IrminGraph.vertex
end

module Make
    (Block: IrminBlock.STORE)
    (Tag  : IrminTag.STORE with type value = Block.key) =
struct

  module Block = Block

  module Tag = Tag
  module T = Tag.Key

  module Key = IrminPath
  module K = Block.Key

  module Value = Block.Contents.Value
  module Contents = Block.Contents
  module C = Value

  module Node = Block.Node
  module N = Node.Value

  module Commit = Block.Commit

  type key = IrminPath.t

  type value = C.t

  type branch = T.t

  module Graph = IrminGraph.Make(K)(T)

  type t = {
    block: Block.t;
    tag: Tag.t;
    branch: T.t;
  }

  let current_branch t = return t.branch

  let block_t    t = t.block
  let tag_t      t = t.tag
  let commit_t   t = Block.commit t.block
  let node_t     t = Block.node t.block
  let contents_t t = Block.contents t.block

  let create ?(branch=T.master) () =
    Block.create () >>= fun block ->
    Tag.create ()   >>= fun tag ->
    return { block; tag; branch }

  let read_head_commit t =
    Tag.read t.tag t.branch >>= function
    | None   -> return_none
    | Some k -> Commit.read (commit_t t) k

  let node_of_commit t c =
    match Commit.node (commit_t t) c with
    | None   -> return IrminNode.empty
    | Some n -> n

  let node_of_opt_commit t = function
    | None   -> return IrminNode.empty
    | Some c -> node_of_commit t c

  let read_head_node t =
    read_head_commit t >>=
    node_of_opt_commit t

  let parents_of_commit = function
    | None   -> []
    | Some r -> [r]

  let update_head_node t ~origin ~f =
    read_head_commit t          >>= fun commit ->
    node_of_opt_commit t commit >>= fun old_node ->
    f old_node                  >>= fun node ->
    if N.equal old_node node then return_unit
    else (
      let parents = parents_of_commit commit in
      Commit.commit (commit_t t) origin ~node ~parents >>= fun (key, _) ->
      (* XXX: the head might have changed since we started the operation *)
      Tag.update t.tag t.branch key
    )

  let map_head_node t path ~f =
    read_head_node t >>= fun node ->
    f (node_t t) node path

  let read t path =
    map_head_node t path ~f:Node.find

  let update t ?origin path contents =
    let origin = match origin with
      | None   -> IrminOrigin.create "Update %s." (IrminPath.to_string path)
      | Some o -> o in
    Log.debugf "update %s" (IrminPath.to_string path);
    update_head_node t ~origin ~f:(fun n ->
        Node.update (node_t t) n path contents
      )

  let remove t ?origin path =
    let origin = match origin with
      | None   -> IrminOrigin.create "Remove %s." (IrminPath.to_string path)
      | Some o -> o in
    update_head_node t ~origin ~f:(fun n ->
        Node.remove (node_t t) n path
      )

  let read_exn t path =
    map_head_node t path ~f:Node.find_exn

  let mem t path =
    map_head_node t path ~f:Node.valid

  (* Return the subpaths. *)
  let list t paths =
    Log.debugf "list";
    let one path =
      read_head_node t >>= fun n ->
      Node.sub (node_t t) n path >>= function
      | None      -> return_nil
      | Some node ->
        let c = Node.succ (node_t t) node in
        let c = Map.keys c in
        let paths = List.map ~f:(fun c -> path @ [c]) c in
        return paths in
    Lwt_list.fold_left_s (fun set p ->
        one p >>= fun paths ->
        let paths = IrminPath.Set.of_list paths in
        return (IrminPath.Set.union set paths)
      ) IrminPath.Set.empty paths
    >>= fun paths ->
    return (IrminPath.Set.to_list paths)

  let dump t =
    Log.debugf "dump";
    read_head_node t >>= fun node ->
    let rec aux seen = function
      | []       -> return (List.sort compare seen)
      | path::tl ->
        list t [path] >>= fun childs ->
        let todo = childs @ tl in
        Node.find (node_t t) node path >>= function
        | None   -> aux seen todo
        | Some v -> aux ((path, v) :: seen) todo in
    begin Node.find (node_t t) node [] >>= function
      | None   -> return_nil
      | Some v -> return [ ([], v) ]
    end
    >>= fun init ->
    list t [[]] >>= aux init

  (* Merge two commits:
     - Search for a common ancestor
     - Perform a 3-way merge *)
  let three_way_merge ?origin t c1 c2 =
    let origin = match origin with
      | None   -> IrminOrigin.create "Merge commits %s and %s"
                    (K.to_string c1) (K.to_string c2)
      | Some o -> o in
    Commit.find_common_ancestor (commit_t t) c1 c2 >>= function
    | None     -> conflict "no common ancestor"
    | Some old ->
      let m = Commit.merge (commit_t t) origin in
      IrminMerge.merge m ~old c1 c2

  let merge_commit t ?origin c1 =
    Tag.read t.tag t.branch >>= function
    | None    -> Tag.update t.tag t.branch c1 >>= ok
    | Some c2 ->
      three_way_merge ?origin t c1 c2 >>| fun c3 ->
      Tag.update t.tag t.branch c3   >>=
      ok

  let clone_force t branch =
    begin Tag.read t.tag branch >>= function
      | None   -> Tag.remove t.tag branch
      | Some c -> Tag.update t.tag branch c
    end >>= fun () ->
    return { t with branch }

  let clone t branch =
    Tag.mem t.tag branch >>= function
    | true  -> return_none
    | false -> clone_force t branch >>= fun t -> return (Some t)

  let merge t  ?origin branch =
    let origin = match origin with
      | Some o -> o
      | None   -> IrminOrigin.create "Merge branch %s."
                    (T.to_string t.branch) in
    Tag.read_exn t.tag branch >>= fun c ->
    merge_commit ~origin t c

  let merge_exn t ?origin tag =
    merge ?origin t tag >>=
    IrminMerge.exn

  let watch_nodes t path =
    Log.infof "Adding a watch on %s" (IrminPath.to_string path);
    let stream = Tag.watch t.tag t.branch in
    IrminMisc.lift_stream (
      map_head_node t path ~f:Node.sub >>= fun node ->
      let old_node = ref node in
      let stream = Lwt_stream.filter_map_s (fun key ->
          Log.debugf "watch: %s" (Block.Key.to_string key);
          Commit.read_exn (commit_t t) key >>= fun commit ->
          begin match Commit.node (commit_t t) commit with
            | None      -> return IrminNode.empty
            | Some node -> node
          end >>= fun node ->
          Node.sub (node_t t) node path >>= fun node ->
          if node = !old_node then return_none
          else (
            old_node := node;
            return (Some (path, key))
          )
        ) stream in
      return stream
    )

  (* watch contents changes. *)
  let watch t path =
    let stream = watch_nodes t path in
    Lwt_stream.filter_map_s (fun (p, k) ->
        if IrminPath.(p = path) then
          Commit.read (commit_t t) k >>= function
          | None   -> return_none
          | Some c ->
            node_of_commit t c >>= fun n ->
            Node.find (node_t t) n p
        else
          return_none
      ) stream

end

module type MAKER =
  functor (K: IrminKey.S) ->
  functor (C: IrminContents.S) ->
  functor (T: IrminTag.S) ->
    S with type key = K.t and type value = C.t and type branch = T.t
