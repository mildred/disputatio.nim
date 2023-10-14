import std/prelude
import std/strformat
import std/parseutils
import prologue
import easy_sqlite3

import ./groups
import ./errors
import ../db/users
import ../db/articles
import ../db/groups
import ../db/votes
import ../context
import ../convert_articles

proc get_vote_num_param(ctx: AppContext, group_guid, article_guid: string, member: GroupMember): float =
  let score_set  = ctx.getFormParamsOption("score_set")
  let vote_set   = ctx.getFormParamsOption("vote_set")
  let vote_param = ctx.getFormParamsOption("vote")
  let score_inc  = ctx.getFormParamsOption("score_inc")
  let score_dec  = ctx.getFormParamsOption("score_dec")

  if score_set.is_some:
    discard score_set.get.parse_float(result)
    # echo &"get_score {group_guid} {article_guid} {member.local_id}"
    let score = ctx.db[].get_score(group_guid, article_guid, member.local_id)
    if score.is_none:
      result = result / member.weight
    else:
      # echo &"Existing score: {score.get}"
      result = (result / member.weight) - score.get.unbounded_vote
  elif vote_set.is_some:
    discard vote_set.get.parse_float(result)
    let score = ctx.db[].get_score(group_guid, article_guid, member.local_id)
    if score.is_some:
      # echo &"Existing score: {score.get}"
      result = result - score.get.unbounded_vote
  elif vote_param.is_some:
    discard vote_param.get.parse_float(result)
  elif score_inc.is_some:
    discard score_inc.get.parse_float(result)
    result = result / member.weight
  elif score_dec.is_some:
    discard score_dec.get.parse_float(result)
    result = - result / member.weight

proc cast_vote(db: var Database, g: GroupItem, member: GroupMember, article_guid: string, vote_num: float): Vote =
  if vote_num != 0:
    result.set_author(g, member)
    result.set_article_guid(article_guid)
    result.vote = vote_num
    result.guid = result.compute_hash()
    result.id = db.save_new(result).get(-1)


proc api_vote*(ctx: Context) {.async, gcsafe.} =
  let db = AppContext(ctx).db
  let group_guid = ctx.getPathParams("groupguid", "")
  let article_guid = ctx.getPathParams("articleguid", "")
  let current_user = db[].get_user(hash_email(ctx.session.getOrDefault("email", "")))

  let (g, member) = db.get_group_auth(group_guid, current_user)

  if g.is_none():
    resp json_response(%*{
      "error": %"not_found"
    }, code = Http404)
    return

  if member.is_none():
    resp json_response(%*{
      "error": %"unauthorized"
    }, code = Http401)
    return

  let vote_num = AppContext(ctx).get_vote_num_param(group_guid, article_guid, member.get)
  let vote = cast_vote(db[], g.get, member.get, article_guid, vote_num)

  let score = db.get_score(g.get.root_guid, article_guid)

  resp json_response(%*{
    "score": %score,
    "vote_guid": %vote.guid,
    "vote": vote.to_json_node()
  }, code = Http200)

proc api_react*(ctx: Context) {.async, gcsafe.} =
  let db = AppContext(ctx).db
  let group_guid = ctx.getPathParams("groupguid", "")
  let article_guid = ctx.getPathParams("articleguid", "")
  let current_user = db[].get_user(hash_email(ctx.session.getOrDefault("email", "")))

  let (g, member) = db.get_group_auth(group_guid, current_user)

  if g.is_none():
    resp json_response(%*{
      "error": %"not_found"
    }, code = Http404)
    return

  if member.is_none():
    resp json_response(%*{
      "error": %"unauthorized member"
    }, code = Http401)
    return

  let html = ctx.getFormParamsOption("html")
  if html.is_none:
    resp json_response(%*{
      "error": %"Missing html parameter"
    }, code = Http400)
    return

  var reaction: Article
  reaction.set_author(g.get)
  reaction.set_group(g.get)
  reaction.from_html(html.get)
  reaction.kind = ctx.getFormParamsOption("kind").get("")
  reaction.reply_guid = article_guid
  reaction.guid = reaction.compute_hash()
  reaction.id = db[].create_article(reaction)

  let vote_num = AppContext(ctx).get_vote_num_param(group_guid, reaction.guid, member.get)

  let vote = cast_vote(db[], g.get, member.get, reaction.guid, vote_num)

  let score = db.get_score(g.get.root_guid, reaction.guid)

  resp json_response(%*{
    "score": %score,
    "vote_guid": %vote.guid,
    "vote": vote.to_json_node(),
    "reaction_guid": %reaction.guid,
    "reaction": reaction.to_json_node(),
  }, code = Http200)
