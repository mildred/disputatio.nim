import std/prelude
import std/strformat
import std/parseutils
import prologue

import ./groups
import ./errors
import ../db/users
import ../db/articles
import ../db/groups
import ../db/votes
import ../context
import ../convert_articles

proc api_vote*(ctx: Context) {.async, gcsafe.} =
  let db = AppContext(ctx).db
  let group_guid = ctx.getPathParams("groupguid", "")
  let article_guid = ctx.getPathParams("articleguid", "")
  let current_user = db[].get_user(hash_email(ctx.session.getOrDefault("email", "")))
  var vote_num: float

  let vote_param = ctx.getFormParamsOption("vote")
  let vote_inc   = ctx.getFormParamsOption("vote_inc")
  let vote_dec   = ctx.getFormParamsOption("vote_dec")

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

  if vote_param.is_some:
    discard vote_param.get.parse_float(vote_num)
  elif vote_inc.is_some:
    discard vote_inc.get.parse_float(vote_num)
    vote_num = vote_num / member.get.weight
  elif vote_dec.is_some:
    discard vote_dec.get.parse_float(vote_num)
    vote_num = - vote_num / member.get.weight

  var vote: Vote
  if vote_num != 0:
    vote.set_author(g.get, member.get)
    vote.set_article_guid(article_guid)
    vote.vote = vote_num
    vote.guid = vote.compute_hash()
    vote.id = db[].save_new(vote).get(-1)

  let score = db.get_score(g.get.root_guid, article_guid)

  resp json_response(%*{
    "score": %score,
    "vote_guid": %vote.guid,
    "vote": vote.to_json_node()
  }, code = Http200)
