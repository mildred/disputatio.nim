import std/strutils
import std/strformat
import std/htmlparser
import std/xmltree
import ./db/articles
import ./views/common

type
  StyleItem* = tuple
    merge_previous: bool
    name: string
    classes: seq[string]
  Style* = tuple
    path: seq[StyleItem]

func parse_style*(style: string): Style =
  for i in style.split(" "):
    var item_str = i
    var item: StyleItem
    item.merge_previous = false
    if item_str.starts_with("="):
      item.merge_previous = true
      item_str = item_str[1..^1]
    elif item_str.starts_with("+"):
      item_str = item_str[1..^1]
    let parts = item_str.split(".")
    if parts.len >= 1:
      case parts[0]
      of "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote":
        item.name = parts[0]
      of "bq":
        item.name = "blockquote"
      else:
        item.name = "div"
      item.classes = parts[1..^1]
      result.path.add(item)
  if result.path.len > 0:
    result.path[result.path.len - 1].merge_previous = false

proc html_close_open_style(parts: var seq[string], last_style, style: Style, open_id: string = "") =
  var close_tags: seq[string]
  var i = last_style.path.len - 1
  while i >= 0:
    #echo &"i={i} drop {last_style.path[i].name}"
    if i >= style.path.len or last_style.path[i].name != style.path[i].name or not style.path[i].merge_previous:
      parts.add(["</", h(last_style.path[i].name), ">"])
      i = i - 1
    else:
      break
  i = i + 1
  while i < style.path.len:
    #echo &"i={i} add {style.path[i].name}"
    parts.add(["<", h(style.path[i].name)])
    if i == style.path.len - 1 and open_id != "":
      parts.add([" id=\"", open_id, "\""])
    if style.path[i].classes.len > 0:
      parts.add([" class=\"", h(style.path[i].classes.join(" ")), "\""])
    parts.add(">")
    i = i + 1

type AfterParagraphCallback = proc(p: Paragraph): string {.gcsafe.}

proc to_html*(article: Article, after: AfterParagraphCallback): string =
  var parts: seq[string] = @[]
  var style, last_style: Style
  for p in article.paragraphs:
    last_style = style
    style = p.style.parse_style()
    html_close_open_style(parts, last_style, style, "paragraph-" & p.guid)
    parts.add(h(p.text))
    if after != nil:
      parts.add(after(p))

  last_style = style
  style.path = @[]
  html_close_open_style(parts, last_style, style)

  result = parts.join("")

func to_html*(article: Article): string =
  {.cast(noSideEffect).}:
    return article.to_html(nil)

proc add_paragraphs_from_nodes(par: var seq[Paragraph], node: XmlNode, path: var seq[string]) =
  var last_text = false
  var first_child = true
  for child in items(node):
    if child.kind == xnElement:
      last_text = false
      var classes = child.attr("class").split(" ")
      while classes.len > 0 and classes[0] == "": classes.del(0)
      let item = (("+" & child.tag) & classes).join(".")
      var new_path = path & item
      par.add_paragraphs_from_nodes(child, new_path)
    elif child.kind == xnText or child.kind == xnCData or child.kind == xnEntity:
      if last_text:
        par[par.len-1].text.add(child.text)
      else:
        last_text = true
        par.add((id: 0, guid: "", style: path.join(" "), text: child.text))
    else:
      continue
    if first_child:
      var i = 0
      while i < path.len:
        if path[i].starts_with("+"):
          path[i] = "=" & path[i][1..^1]
        i = i + 1

proc from_html*(article: var Article, html_data: string, parent_patch_guid: string = "") =
  article.paragraphs = @[]
  let html = html_data.parse_html()
  var path: seq[string] = @[]
  if html.kind == xnText or html.kind == xnCData or html.kind == xnEntity:
    article.paragraphs.add((id: 0, guid: "", style: "", text: html.text))
  else:
    add_paragraphs_from_nodes(article.paragraphs, html, path)

  var i = 0
  while i < article.paragraphs.len:
    article.paragraphs[i].guid = article.paragraphs[i].compute_hash()
    i = i + 1

  var pat: Patch
  pat.parent_guid = parent_patch_guid
  pat.paragraphs  = article.paragraphs
  pat.guid = pat.compute_hash()

  article.patch_guid = pat.guid
