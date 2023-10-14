import std/json
import std/options
import std/algorithm
import easy_sqlite3

import ./guid
import ./groups
import ./articles
import ./utils

type
  Vote* = tuple
    id: int
    guid: string
    group_id: int
    group_guid: string
    member_id: int
    article_id: Option[int]
    article_guid: string
    paragraph_rank: Option[int]
    vote: float
    timestamp: float

proc to_json_node*(vote: Vote): JsonNode =
  result = %*{
    "t": %"vote",
    "g": vote.group_guid,
    "m": vote.member_id,
    "a": vote.article_guid,
    "v": vote.vote,
    "ts": vote.timestamp
  }
  if vote.paragraph_rank.is_some():
    result["p"] = %vote.paragraph_rank.get()

proc compute_hash*(obj: Vote): string =
  result = obj.to_json_node().compute_hash()

proc set_author*(vote: var Vote, group: GroupItem, member: GroupMember) =
  if vote.timestamp == 0: vote.timestamp = get_julianday()
  vote.group_id = group.id
  vote.group_guid = group.guid
  vote.member_id = member.local_id

proc set_article*(vote: var Vote, article: Article, paragraph_rank: int = -1) =
  if vote.timestamp == 0: vote.timestamp = get_julianday()
  vote.article_id = some(article.id)
  vote.article_guid = article.guid
  if paragraph_rank >= 0:
    vote.paragraph_rank = some(paragraph_rank)

proc set_article_guid*(vote: var Vote, article_guid: string, paragraph_rank: int = -1) =
  if vote.timestamp == 0: vote.timestamp = get_julianday()
  vote.article_guid = article_guid
  if paragraph_rank >= 0:
    vote.paragraph_rank = some(paragraph_rank)

iterator get_votes(group_guid: string, member_id: int, article_guid: string, paragraph_rank: Option[int]): Vote {.importdb: """
  SELECT  id, guid, group_id, group_guid,
          member_id, article_id, article_guid, paragraph_rank, vote
  FROM    group_item gi1
          JOIN group_item gi1 ON gi1.root_guid = gi2.root_guid
          JOIN vote v ON v.group_id = gi2.id
  WHERE   gi1.guid = $group_guid AND
          v.member_id = $member_id AND
          v.article_guid = $article_guid AND
          v.paragraph_rank = $paragraph_rank
""".} = discard

proc get_votes*(db: ref Database, group_guid: string, member_id: int, article_guid: string, paragraph_rank: int = -1): seq[Vote] =
  result = @[]
  var par_rank: Option[int]
  if paragraph_rank >= 0:
    par_rank = some(paragraph_rank)

  for v in db[].get_votes(group_guid, member_id, article_guid, par_rank):
    result.add(v)

proc insert_vote(guid: string, group_id: int, group_guid: string, member_id: int, article_id: Option[int], article_guid: string, paragraph_rank: Option[int], vote: float): Option[tuple[id: int]] {.importdb: """
  INSERT INTO vote (guid, group_id, group_guid, member_id, article_id, article_guid, paragraph_rank, vote)
  VALUES (
    $guid, $group_id, $group_guid, $member_id,
    COALESCE($article_id, (SELECT id FROM article a WHERE a.guid = $article_guid AND a.group_guid = $group_guid)),
    $article_guid, $paragraph_rank, $vote)
  ON CONFLICT DO NOTHING
  RETURNING id
""".}

proc save_new*(db: var Database, v: Vote): Option[int] =
  assert(v.guid != "")
  let res = db.insert_vote(v.guid, v.group_id, v.group_guid, v.member_id, v.article_id, v.article_guid, v.paragraph_rank, v.vote)
  if res.is_some: result = some(res.get.id)

proc get_score*(group_guid, article_guid: string, member_id: int): Option[tuple[weight: float, unbounded_vote: float, vote: float, score: float]] {.importdb: """
  SELECT member_weight, unbounded_vote, vote, score
  FROM article_member_score
  WHERE group_guid = $group_guid AND article_guid = $article_guid AND member_id = $member_id
""".}

proc get_score(group_guid, article_guid: string): Option[tuple[score: float]] {.importdb: """
  SELECT score
  FROM article_score
  WHERE group_guid = $group_guid AND article_guid = $article_guid
""".}

proc get_score*(db: ref Database, group_guid, article_guid: string): Option[float] =
  let res = db[].get_score(group_guid, article_guid)
  if res.is_some: result = some(res.get.score)

