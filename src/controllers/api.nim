import std/prelude
import std/strutils
import std/strformat
import std/base64
import std/uri
import std/json

import prologue
import easy_sqlite3

import ../context

proc attach_database_master(file: string) {.importdb: """
  ATTACH DATABASE $file AS master
""".}

proc get*(ctx: Context) {.async, gcsafe.} =
  resp json_response(%*{
    "ok": %true
  })

proc post*(ctx: Context) {.async, gcsafe.} =
  let ctx = AppContext(ctx)
  let req = parse_json(ctx.request.body())

  let sql = req["sql"].to(string)
  if sql == "":
    resp json_response(%*{ "ok": %true })
    return

  var db = initDatabase(":memory:")
  db.attach_database_master(ctx.db_file)
  db.exec("""
    CREATE TEMP VIEW group_items AS
    SELECT * FROM master.group_items WHERE group_type = 3;
  """)
  db.exec("""
    CREATE TEMP VIEW group_members AS
    SELECT * FROM master.group_members WHERE group_item_id IN (SELECT id FROM group_items);
  """)
  db.exec("""
    CREATE TEMP VIEW articles AS
    SELECT * FROM master.articles WHERE group_id IN (SELECT id FROM group_items);
  """)
  db.exec("""
    CREATE TEMP VIEW patches AS
    SELECT * FROM master.patches WHERE id IN (SELECT patch_id FROM articles);
  """)
  db.exec("""
    CREATE TEMP VIEW patch_items AS
    SELECT * FROM master.patch_items WHERE patch_id IN (SELECT patch_id FROM articles);
  """)
  db.exec("""
    CREATE TEMP VIEW paragraphs AS
    SELECT * FROM master.paragraphs WHERE id IN (SELECT paragraph_id FROM patch_items);
  """)
  db.setAuthorizer do (req: AuthorizerRequest) -> AuthorizerResult:
    result = deny
    case req.caller
    of "group_items", "group_members", "articles", "patches", "patch_items", "paragraphs":
      case req.action_code
      of select:
        result = ok
      of read:
        result = ok
      else:
        discard
    of "temp", "":
      case req.action_code
      of select, recursive:
        result = ok
      of read:
        result = ok
      of function:
        case req.function_name
        of  "count", "min", "max", "group_concat",
            "printf", "lower", "upper",
            "row_number", "rank", "dense_rank":
          result = ok
        else:
          discard
      else:
        discard
    if result != ok:
      echo &"authorize {req.repr} = {result}"

  let st = db.newStatement(sql)
  var res_lines: seq[JsonNode]
  for line in st.rows():
    var res_line: seq[JsonNode]
    for col in line:
      case col.data_type
      of dt_integer:
        res_line.add(%col[int])
      of dt_float:
        res_line.add(%col[float64])
      of dt_text:
        res_line.add(%col[string])
      of dt_blob:
        res_line.add(%col[string])
      of dt_null:
        res_line.add(newJNull())
    res_lines.add(%res_line)

  resp json_response(%*{ "rows": %res_lines })
