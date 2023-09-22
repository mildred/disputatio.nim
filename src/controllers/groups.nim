import std/strformat
import std/strutils
import std/parseutils
import std/json
import prologue

import ./errors
import ../context
import ../db/users
import ../db/groups
import ../db/articles
import ../views/layout
import ../views/groups as vgroups

export compute_payload

proc api_create*(ctx: Context) {.async, gcsafe.} =
  let db  = AppContext(ctx).db
  let req = parse_json(ctx.request.body())
  let gi  = new(GroupItem)

  gi[] = GroupItem.from_json(req)

  if gi[].parent_guid != "":
    # TODO: check if the new group item is authorized
    # - must be authored by a group member
    # - the group member must have the corresponding permissions
    # - or the group is an open group and the new item only adds the current
    #   user.
    # - ...
    resp json_response(%*{
      "error": %"not_authorized"
    }, code = Http400)
    return

  gi[].compute_new()
  db[].save_new(gi[])

  resp json_response(%*{
    "group_guid": %gi.guid,
    # "group_payload": %gi[].compute_payload(),
    "group": gi[].to_json_node()
  })

proc create*(ctx: Context) {.async, gcsafe.} =
  let db = AppContext(ctx).db
  let gi = new(GroupItem)
  let preset = ctx.getFormParamsOption("_preset").get("")
  gi.name = ctx.getFormParamsOption("name").get("")
  gi.seed_userdata = ctx.getFormParamsOption("seed_userdata").get("")
  discard ctx.getFormParamsOption("others_members_weight").get("0").parseFloat(gi.others_members_weight)
  discard ctx.getFormParamsOption("group_type").get("0").parseInt(gi.group_type)
  discard ctx.getFormParamsOption("moderation_default_score").get("0").parseFloat(gi.moderation_default_score)
  # TODO: construct a list of participating pods
  # for each pod, propagate the group item

  # In any case add self to group
  let current_user = db[].get_user(hash_email(ctx.session.getOrDefault("email", "")))
  var m: GroupMember
  m.local_id = gi[].allocate_member_id()
  discard ctx.getFormParamsOption("self_weight").get("1").parseFloat(m.weight)
  m.nickname = ctx.getFormParamsOption("self_nickname").get(gi[].name)
  m.user_id = current_user.get.id
  for p in current_user.get.pods:
    var i: GroupMemberItem
    i.pod_url = p.pod_url
    i.local_user_id = p.local_user_id
    m.items.add(i)

  var member_id: int = 0
  if ctx.getFormParamsOption("empty_group").is_none():
    gi[].members.add(m)
    member_id = m.local_id

  if preset == "identity":
    # Private identity : note to self
    gi[].group_type = 0
    gi[].compute_new()
    db[].save_new(gi[], group_member = member_id)

    # Public identity where our pod coordinates can be found and a place for
    # public messages (public blog)
    gi[].group_type = 3
    gi[].compute_new()
    db[].save_new(gi[], group_member = member_id)

    resp redirect(&"/", code = Http303)

  else:
    gi[].compute_new()
    db[].save_new(gi[], group_member = member_id)
    resp redirect(&"/@{gi.root_guid}/", code = Http303)

proc get_group*(ctx: Context): tuple[group: Option[GroupItem], member: Option[GroupMember]] {.gcsafe.} =
  let db = AppContext(ctx).db
  let group_guid = ctx.getPathParams("groupguid", "")
  let current_user = db[].get_user(hash_email(ctx.session.getOrDefault("email", "")))

  var g = db[].get_group(group_guid)
  var member: Option[GroupMember]

  if g.is_some() and current_user.is_some:
    member = g.get.find_current_user(current_user.get.id)
    if g.get.group_type == 0 and member.is_none():
      g = none(GroupItem)

  result = (g, member)

proc join*(ctx: Context) {.async, gcsafe.} =
  let db = AppContext(ctx).db
  let group_guid = ctx.getPathParams("groupguid", "")
  let current_user = db[].get_user(hash_email(ctx.session.getOrDefault("email", "")))

  let (g, member) = ctx.get_group()

  if g.is_none(): return ctx.go404()

  # Announce only groups cannot be joined by link only
  if g.get.others_members_weight == 0 and g.get.moderation_default_score == 0:
    resp redirect(&"/@{g.get.root_guid}/", code = Http303)

  var m: GroupMember
  m.local_id = g.get.allocate_member_id()
  m.weight = g.get.others_members_weight
  m.nickname = ctx.getFormParamsOption("self_nickname").get
  m.user_id = current_user.get.id
  for p in current_user.get.pods:
    var i: GroupMemberItem
    i.pod_url = p.pod_url
    i.local_user_id = p.local_user_id
    m.items.add(i)

  var gi = g.get
  gi.members.add(m)
  gi.parent_id = g.get.id
  gi.parent_guid = g.get.guid
  gi.compute_new()
  db[].save_new(gi, g, group_member = m.local_id)

  if AppContext(ctx).api:
    resp json_response(%*{
      "member": m.to_json_node(),
      "group_item": gi.to_json_node()
    })
  else:
    resp redirect(&"/@{gi.root_guid}/", code = Http303)

proc show*(ctx: Context) {.async, gcsafe.} =
  let db = AppContext(ctx).db
  let (g, member) = ctx.get_group()

  if g.is_none(): return ctx.go404()

  let posts = db[].group_get_posts(g.get)

  resp ctx.layout(group_show(g.get, member, posts), title = &"{g.get.name} | groups")

proc json_info*(ctx: Context) {.async, gcsafe.} =
  let db = AppContext(ctx).db
  let (g, member) = ctx.get_group()

  if g.is_none():
    resp json_response(%*{
      "error": %"not_found"
    }, code = Http404)
    return

  resp json_response(%*{
    "group": %g.get.to_json_node(),
    "member": (if member.is_none(): newJNull() else: member.get().to_json_node()),
  })
