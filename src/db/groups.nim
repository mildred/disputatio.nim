import std/json
import std/options
import std/algorithm
import easy_sqlite3

import ./guid

type
  GroupMemberItem* = tuple
    id: int
    group_member_id: int
    pod_url: string
    local_user_id: string

  GroupMember* = tuple
    id: int
    local_id: int
    group_item_id: int
    weight: float
    nickname: string
    user_id: int
    items: seq[GroupMemberItem]

  GroupItem* = tuple
    id: int
    guid: string
    root_guid: string
    parent_id: int
    parent_guid: string
    group_type: int
    name: string
    seed_userdata: string
    others_members_weight: float
    moderation_default_score: float
    members: seq[GroupMember]

  GroupValidationError* = object of CatchableError
    parent_guid_mismatch:           bool
    root_guid_mismatch:             bool
    invalid_member_order:           int
    invalid_self_join:              bool
    invalid_self_join_weight:       bool
    invalid_owner_weight_update:    bool
    non_authorized_pod_update:      bool
    group_type_mismatch:            bool
    non_member_update:              bool
    non_owner_title_change:         bool
    invalid_others_weight:          bool
    non_owner_default_score_change: bool
    invalid_remove_member:          bool
    invalid_member_nickname_change: int
    invalid_member_weight_decrease: int
    invalid_member_weight_increase: int
    invalid_new_member_weight:      int
    invalid_member_item_ordering:   int
    invalid_pod_removal:            int
    invalid_pod_addition:           int

proc validate_group_item*(item: GroupItem, parent: Option[GroupItem] = none(GroupItem), member_id: int = 0, from_pod: string = ""): Option[GroupValidationError] =
  var res: GroupValidationError

  if (parent.is_some and item.parent_guid != parent.get.guid) or
     (parent.is_none and item.parent_guid != ""):
    res.parent_guid_mismatch = true
    result = some(res)

  if (parent.is_some and parent.get.parent_guid == "" and item.root_guid != parent.get.guid) or
     (parent.is_some and parent.get.parent_guid != "" and item.root_guid != parent.get.root_guid) or
     (parent.is_none and item.root_guid != ""):
    res.root_guid_mismatch = true
    result = some(res)

  var new_max_weight: float
  var new_max_weight_set = false
  for i, m in item.members:
    if m.local_id != i + 1:
      res.invalid_member_order = i + 1
      result = some(res)
    if not new_max_weight_set or m.weight > new_max_weight:
      new_max_weight = m.weight
      new_max_weight_set = true

  if parent.is_none:
    return

  # Past this point, we only check updates to the group item and if is allowed
  # within the context of the parent item

  var member_found = (member_id > 0 and member_id <= len(item.members))
  if not member_found:
    res.non_member_update = true
    result = some(res)
    return

  let member = item.members[member_id - 1]
  assert member.local_id == member_id

  if not member_found:
    res.non_member_update = true
    result = some(res)
    return

  var old_max_weight: float
  var old_max_weight_set = false
  for i, m in parent.get.members:
    if not old_max_weight_set or m.weight > old_max_weight:
      old_max_weight = m.weight
      old_max_weight_set = true

  var old_member: Option[GroupMember] = none(GroupMember)
  var member_weight = parent.get.others_members_weight
  if member_id - 1 <= parent.get.members.len:
    old_member = some(parent.get.members[member_id - 1])
    member_weight = old_member.get.weight

  if old_member.is_none and parent.get.group_type == 0:
    res.invalid_self_join = true
    result = some(res)

  if old_member.is_none and member.weight > parent.get.others_members_weight:
    res.invalid_self_join_weight = true
    result = some(res)

  let owner = (member_weight == old_max_weight)

  # Past this point, the member is valid and we can use it to validate the new
  # group item

  if old_max_weight != new_max_weight:
    for i, m0 in parent.get.members:
      let m1 = item.members[i]
      if m0.weight == old_max_weight and m1.weight != new_max_weight:
        # All owners in previous blocks must continue to be owner (but new
        # owners can appear)
        res.invalid_owner_weight_update = true
        result = some(res)

  if from_pod != "":
    var pod_found = false
    for itm in member.items:
      if itm.pod_url == from_pod:
        pod_found = true
        break
    if not pod_found:
      res.non_authorized_pod_update = true
      result = some(res)

  if parent.get.group_type != item.group_type:
    res.group_type_mismatch = true
    result = some(res)

  if parent.get.name != item.name and not owner:
    res.non_owner_title_change = true
    result = some(res)

  if parent.get.others_members_weight != item.others_members_weight and
     item.others_members_weight > member_weight:
    res.invalid_others_weight = true
    result = some(res)

  if parent.get.moderation_default_score != item.moderation_default_score and not owner:
    res.non_owner_default_score_change = true
    result = some(res)

  if parent.get.members.len > item.members.len:
    res.invalid_remove_member = true
    result = some(res)

  for i, m1 in item.members:
    let self = (m1.local_id == member_id)
    let existing_member = (i < parent.get.members.len)

    if existing_member:
      let m0 = parent.get.members[i]
      assert m0.local_id == m1.local_id
      # Existing member, check for changes

      if m0.weight == old_max_weight and m1.weight == new_max_weight:
        discard
        # Legitimate owner weight change

      elif m0.weight > m1.weight: # weight decrease
        if not self and m1.weight >= member_weight: 
          # only allowed for self and members with lower weight
          res.invalid_member_weight_decrease = i + 1
          result = some(res)

      elif m0.weight < m1.weight: # weight increase
        if self or m1.weight > member_weight:
          # not allowed for self, but allowed for other members with less weight
          res.invalid_member_weight_increase = i + 1
          result = some(res)

      if m0.nickname != m1.nickname and not self and m1.weight >= member.weight:
        # Nickname changed is only allowed for oneself and members with lower
        # weight
        res.invalid_member_nickname_change = i + 1
        result = some(res)

      for itm0 in m0.items:
        var removed = true
        for itm1 in m1.items:
          if itm0.pod_url == itm1.pod_url and itm0.local_user_id == itm1.local_user_id:
            removed = false
            break
        if removed and not self and m1.weight >= member_weight:
          # Pod removal should be performed by self or strictly higher
          # priviledged member
          res.invalid_pod_removal = i + 1
          result = some(res)
    else:
      # New member
      if m1.weight > member_weight:
        res.invalid_new_member_weight = i + 1
        result = some(res)

    var last_pod_url = ""
    var last_pod_id = ""
    for itm in m1.items:
      if (itm.pod_url  < last_pod_url) or
         (itm.pod_url == last_pod_url and itm.local_user_id <= last_pod_id):
        res.invalid_member_item_ordering = i + 1
        result = some(res)

      last_pod_url = itm.pod_url
      last_pod_id  = itm.local_user_id

      if not existing_member:
        # Do not check pods for new members
        continue

      let itm1 = itm
      let m0 = parent.get.members[i]

      var added = true
      for itm0 in m0.items:
        if itm0.pod_url == itm1.pod_url and itm0.local_user_id == itm1.local_user_id:
          added = false
          break

      if added and not self:
        res.invalid_pod_addition = i + 1
        result = some(res)


proc cmp(a, b: GroupMemberItem): int =
  result = system.cmp[string](a.pod_url, b.pod_url)
  if result != 0: return result
  result = system.cmp[string](a.local_user_id, b.local_user_id)

proc cmp(a, b: GroupMember): int =
  result = system.cmp[int](a.local_id, b.local_id)

proc from_json*(t: typedesc[GroupMemberItem], j: JsonNode): GroupMemberItem =
  result.pod_url       = j[0].get_str
  result.local_user_id = j[1].get_str

proc to_json_node(items: seq[GroupMemberItem]): JsonNode =
  result = newJArray()
  for m in items.sorted(cmp):
    result.add(%*[m.pod_url, m.local_user_id])

proc to_json_node*(m: GroupMember): JsonNode =
  result = %*{
    "id": m.local_id,
    "nick": m.nickname,
    "w": m.weight,
    "addrs": m.items.to_json_node()
  }

proc from_json*(t: typedesc[GroupMember], j: JsonNode): GroupMember =
  result.local_id = j["id"].get_int
  result.nickname = j["nick"].get_str
  result.weight   = j["w"].get_float
  result.items    = @[]
  for itm in items(j["addrs"]):
    result.items.add(GroupMemberItem.from_json(itm))

proc to_json_node(members: seq[GroupMember]): JsonNode =
  result = newJArray()
  for m in members.sorted(cmp):
    result.add(m.to_json_node())

proc to_json_node*(gi: GroupItem): JsonNode =
  result = %*{
    "t": "group-item",
    "n": gi.name,
    "gt": gi.group_type,
    "ud": gi.seed_userdata,
    "ow": gi.others_members_weight,
    "s": gi.moderation_default_score,
    "m": gi.members.to_json_node()
  }
  if gi.root_guid != "" and gi.root_guid != gi.guid:
    result["root"] = %*gi.root_guid
  if gi.parent_guid != "":
    result["parent"] = %*gi.parent_guid

proc from_json*(t: typedesc[GroupItem], j: JsonNode): GroupItem =
  assert j["t"].get_str == "group-item"
  result.members       = @[]
  result.name          = j["n"].get_str
  result.group_type    = j["gt"].get_int
  result.seed_userdata = j["ud"].get_str
  result.others_members_weight    = j["ow"].get_float
  result.moderation_default_score = j["s"].get_float
  if j.has_key("root"):
    result.root_guid = j["root"].get_str
  if j.has_key("parent"):
    result.parent_guid = j["parent"].get_str
  for member in items(j["m"]):
    result.members.add(GroupMember.from_json(member))

proc compute_hash*(obj: GroupItem): string =
  result = obj.to_json_node().compute_hash()

proc compute_payload*(obj: GroupItem): string =
  result = obj.to_json_node().compute_payload()

proc compute_new*(gi: var GroupItem) =
  gi.guid = gi.compute_hash()
  if gi.parent_guid == "": gi.root_guid = gi.guid

proc insert_group_item(guid, root_guid: string, parent_guid: Option[string], parent_id: Option[int], name, seed_userdata: string, group_type: int, others_members_weight: float, moderation_default_score: float): Option[tuple[id: int]] {.importdb: """
  INSERT INTO group_item (guid, root_guid, parent_id, parent_guid, name, seed_userdata, group_type, others_members_weight, moderation_default_score)
  VALUES ($guid, $root_guid, $parent_id, $parent_guid, $name, $seed_userdata, $group_type, $others_members_weight, $moderation_default_score)
  ON CONFLICT DO NOTHING
  RETURNING id
""".}

proc insert_group_member(local_id: int, group_item_id: int, nickname: string, weight: float, user_id: int): tuple[id: int] {.importdb: """
  INSERT INTO group_member (local_id, obsolete, obsoleted_by, group_item_id, nickname, weight, user_id)
  VALUES ($local_id, FALSE, NULL, $group_item_id, $nickname, $weight, CASE WHEN $user_id <= 0 THEN NULL ELSE $user_id END)
  RETURNING id
""".}

proc insert_group_member_item(group_member_id: int, pod_url: string, local_user_id: string): tuple[id: int] {.importdb: """
  INSERT INTO group_member_item (group_member_id, pod_url, local_user_id)
  VALUES ($group_member_id, $pod_url, $local_user_id)
  RETURNING id
""".}

proc select_latest_group_item_by_guid(guid: string): Option[tuple[
    id: int,
    guid: string,
    root_guid: string,
    parent_id: int,
    parent_guid: string,
    group_type: int,
    name: string,
    seed_userdata: string,
    others_members_weight: float,
    moderation_default_score: float
]] {.importdb: """
  SELECT  id, guid, root_guid, parent_id, parent_guid, group_type, name,
          seed_userdata, others_members_weight, moderation_default_score
  FROM    group_item
  WHERE root_guid = $guid AND NOT EXISTS (
    SELECT gi.id FROM group_item gi WHERE gi.parent_id = group_item.id
  )
""".} = discard

iterator select_root_group_item_by_user_id(user_id: int): tuple[
    id: int,
    guid: string,
    root_guid: string,
    parent_id: int,
    parent_guid: string,
    group_type: int,
    name: string,
    seed_userdata: string,
    others_members_weight: float,
    moderation_default_score: float
] {.importdb: """
  SELECT  id, guid, root_guid, parent_id, parent_guid, group_type, name,
          seed_userdata, others_members_weight, moderation_default_score
  FROM    group_item
  WHERE guid IN (
    SELECT root_guid
    FROM group_item gi JOIN group_member gm ON gi.id = gm.group_item_id
    WHERE NOT obsolete AND user_id = $user_id
  )
""".} = discard

iterator select_group_members(group_id: int): tuple[
    id: int,
    local_id: int,
    group_item_id: int,
    weight: float,
    nickname: string,
    user_id: int
] {.importdb: """
  SELECT id, local_id, group_item_id, weight, nickname, user_id
  FROM group_member
  WHERE group_item_id = $group_id
""".} = discard

iterator select_group_member_items(group_member_id: int): tuple[
    id: int,
    group_member_id: int,
    pod_url: string,
    local_user_id: string
] {.importdb: """
  SELECT id, group_member_id, pod_url, local_user_id
  FROM group_member_item
  WHERE group_member_id = $group_member_id
""".} = discard

proc save_new*(db: var Database, gi: GroupItem) =
  db.transaction:
    assert(gi.guid != "")
    for member in gi.members:
      assert(member.items.len > 0, "group member must have pods")

    let root_guid = if gi.root_guid == "": gi.guid else: gi.root_guid

    var parent_id: Option[int]
    var parent_guid: Option[string]

    if root_guid != gi.guid:
      assert(gi.parent_id >= 0, "group item must have a parent id")
      assert(gi.parent_guid != "", "group item must have a parent guid")
      parent_id = some(gi.parent_id)
      parent_guid = some(gi.parent_guid)

    let group = db.insert_group_item(gi.guid, root_guid, parent_guid, parent_id, gi.name, gi.seed_userdata, gi.group_type, gi.others_members_weight, gi.moderation_default_score)
    if group.is_some():
      for member in gi.members:
        let mem = db.insert_group_member(member.local_id, group.get.id, member.nickname, member.weight, member.user_id)
        for item in member.items:
          discard db.insert_group_member_item(mem.id, item.pod_url, item.local_user_id)

proc list_groups_with_user*(db: var Database, user_id: int): seq[GroupItem] =
  result = @[]
  for g in db.select_root_group_item_by_user_id(user_id):
    let gi: GroupItem = (
      id: g.id, guid: g.guid, root_guid: g.root_guid, parent_id: g.parent_id,
      parent_guid: g.parent_guid, group_type: g.group_type, name: g.name,
      seed_userdata: g.seed_userdata,
      others_members_weight: g.others_members_weight,
      moderation_default_score: g.moderation_default_score,
      members: @[])
    result.add(gi)

proc get_group*(db: var Database, guid: string): Option[GroupItem] =
  let gi = db.select_latest_group_item_by_guid(guid)
  if gi.is_none(): return none(GroupItem)

  let g = gi.get()
  var res: GroupItem = (
      id: g.id, guid: g.guid, root_guid: g.root_guid, parent_id: g.parent_id,
      parent_guid: g.parent_guid, group_type: g.group_type, name: g.name,
      seed_userdata: g.seed_userdata,
      others_members_weight: g.others_members_weight,
      moderation_default_score: g.moderation_default_score,
      members: @[])

  for m in db.select_group_members(g.id):
    var member: GroupMember = (
      id: m.id, local_id: m.local_id, group_item_id: m.group_item_id,
      weight: m.weight, nickname: m.nickname, user_id: m.user_id, items: @[])
    for i in db.select_group_member_items(m.id):
      let item: GroupMemberItem = i
      member.items.add(item)
    res.members.add(member)

  return some(res)

proc find_current_user*(g: GroupItem, user_id: int): Option[GroupMember] =
  for member in g.members:
    if member.user_id == user_id:
      return some(member)

proc allocate_member_id*(g: GroupItem): int =
  result = 1
  for m in g.members:
    if result <= m.local_id:
      result = m.local_id + 1

