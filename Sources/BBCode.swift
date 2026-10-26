// Turns a Steam Workshop description (Steam BBCode) into HTML that looks
// like the description on a Workshop item page.

import Foundation

enum BBCode {
  static func html(_ source: String) -> String {
    var text = source.replacingOccurrences(of: "\r\n", with: "\n")

    // [noparse] and [code] keep their contents as typed.
    var kept: [String] = []
    func keep(_ html: String) -> String {
      kept.append(html)
      return "\u{E000}\(kept.count - 1)\u{E001}"
    }
    text = replace(text, "\\[noparse\\]([\\s\\S]*?)\\[/noparse\\]") { keep(escape($0[1])) }
    text = replace(text, "\\[code\\]\\n?([\\s\\S]*?)\\[/code\\]\\n?") { keep("<pre class=\"bb_code\">\(escape($0[1]))</pre>") }

    text = escape(text)

    // Bare links become clickable, as on Steam. Links inside [url] and [img]
    // follow "]" or "=", so they are left for those tags.
    text = replace(text, "(^|[\\s(])(https?://[^\\s<\\[\\]\"]+)") { "\($0[1])<a href=\"\($0[2])\">\($0[2])</a>" }

    // Block tags swallow one line break on each side, as on Steam.
    let block = "(\\[/?(?:h1|h2|h3|list|olist|\\*|hr|quote(?:=[^\\]]*)?|table[^\\]]*|tr|td|th)\\])"
    text = replace(text, "\\n?" + block + "\\n?") { $0[1] }

    let simple: [(String, String)] = [
      ("h1", "<div class=\"bb_h1\">"), ("/h1", "</div>"),
      ("h2", "<div class=\"bb_h2\">"), ("/h2", "</div>"),
      ("h3", "<div class=\"bb_h3\">"), ("/h3", "</div>"),
      ("b", "<b>"), ("/b", "</b>"), ("i", "<i>"), ("/i", "</i>"),
      ("u", "<u>"), ("/u", "</u>"), ("strike", "<s>"), ("/strike", "</s>"),
      ("spoiler", "<span class=\"bb_spoiler\"><span>"), ("/spoiler", "</span></span>"),
      ("list", "<ul class=\"bb_ul\">"), ("/list", "</ul>"),
      ("olist", "<ol>"), ("/olist", "</ol>"), ("*", "<li>"),
      ("hr", "<hr>"), ("/hr", ""),
      ("quote", "<blockquote class=\"bb_blockquote\">"), ("/quote", "</blockquote>"),
      ("tr", "<tr>"), ("/tr", "</tr>"), ("td", "<td>"), ("/td", "</td>"), ("th", "<th>"), ("/th", "</th>"),
      ("/table", "</table>"),
    ]
    for (tag, html) in simple {
      text = text.replacingOccurrences(of: "[\(tag)]", with: html, options: .caseInsensitive)
    }

    text = replace(text, "\\[quote=([^\\]]*)\\]") {
      "<blockquote class=\"bb_blockquote with_author\"><div class=\"bb_quoteauthor\">Originally posted by <b>\($0[1])</b>:</div>"
    }
    text = replace(text, "\\[table([^\\]]*)\\]") { m in
      var classes = ["bb_table"]
      if m[1].contains("noborder=1") { classes.append("bb_table_noborder") }
      if m[1].contains("equalcells=1") { classes.append("bb_table_equalcells") }
      return "<table class=\"\(classes.joined(separator: " "))\">"
    }
    text = replace(text, "\\[url=([^\\]]+)\\]([\\s\\S]*?)\\[/url\\]") { "<a href=\"\(href($0[1]))\">\($0[2])</a>" }
    text = replace(text, "\\[url\\]([\\s\\S]*?)\\[/url\\]") { "<a href=\"\(href($0[1]))\">\($0[1])</a>" }
    text = replace(text, "\\[img\\]([\\s\\S]*?)\\[/img\\]") { "<img src=\"\(href($0[1]))\">" }
    text = replace(text, "\\[previewyoutube=([A-Za-z0-9_-]+)[^\\]]*\\]\\s*\\[/previewyoutube\\]") {
      "<a class=\"bb_youtube\" href=\"https://www.youtube.com/watch?v=\($0[1])\"><img src=\"https://img.youtube.com/vi/\($0[1])/hqdefault.jpg\"><span>▶ YouTube</span></a>"
    }

    text = text.replacingOccurrences(of: "\n", with: "<br>")
    for (i, html) in kept.enumerated() {
      text = text.replacingOccurrences(of: "\u{E000}\(i)\u{E001}", with: html)
    }
    return text
  }

  static func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  /// Links keep only http(s); anything else is dropped.
  static func href(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") { return t }
    if t.lowercased().hasPrefix("www.") { return "https://" + t }
    return "#"
  }

  /// Regex replace where the closure gets the match and its groups.
  static func replace(_ s: String, _ pattern: String, _ make: ([String]) -> String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
    let ns = s as NSString
    var out = ""
    var last = 0
    for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
      out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
      let groups = (0..<m.numberOfRanges).map { i -> String in
        let r = m.range(at: i)
        return r.location == NSNotFound ? "" : ns.substring(with: r)
      }
      out += make(groups)
      last = m.range.location + m.range.length
    }
    out += ns.substring(from: last)
    return out
  }

  /// Full page used by the preview pane, styled after Steam's Workshop page.
  static let page = """
  <!doctype html><html><head><meta charset="utf-8"><style>
  html,body{margin:0;background:#1b2838;}
  body{padding:16px 18px;color:#acb2b8;font:14px/1.45 "Motiva Sans",Arial,Helvetica,sans-serif;word-wrap:break-word;}
  #title{color:#fff;font-size:26px;line-height:1.2;margin:0 0 4px;font-weight:300;}
  #label{color:#56707f;font-size:11px;text-transform:uppercase;letter-spacing:.06em;margin:0 0 14px;}
  #c{background:rgba(0,0,0,.2);padding:14px 16px;border-radius:2px;}
  a{color:#ebebeb;text-decoration:none;} a:hover{color:#66c0f4;}
  .bb_h1{font-size:20px;color:#5aa9d6;margin:6px 0 4px;font-weight:normal;}
  .bb_h2{font-size:17px;color:#5aa9d6;margin:6px 0 4px;font-weight:normal;}
  .bb_h3{font-size:15px;color:#5aa9d6;margin:4px 0 2px;font-weight:bold;}
  ul.bb_ul,ol{margin:4px 0 6px;padding-left:22px;} li{margin:1px 0;}
  hr{border:0;border-top:1px solid #4f5c69;margin:10px 0;}
  .bb_blockquote{margin:6px 0;padding:8px 12px;background:rgba(255,255,255,.04);border:1px solid #3a4a5a;color:#9aa3ad;font-size:13px;}
  .bb_quoteauthor{font-size:12px;margin-bottom:4px;}
  .bb_code{background:#0f1720;border:1px solid #2a3542;padding:8px;color:#c6d4df;font:12px Menlo,monospace;white-space:pre-wrap;margin:6px 0;}
  .bb_spoiler{background:#000;color:#000;border-radius:2px;padding:0 2px;} .bb_spoiler:hover{color:#fff;}
  .bb_spoiler>span{visibility:hidden;} .bb_spoiler:hover>span{visibility:visible;}
  table.bb_table{border-collapse:collapse;margin:6px 0;} .bb_table td,.bb_table th{border:1px solid #4f5c69;padding:4px 8px;}
  .bb_table_noborder td,.bb_table_noborder th{border:0;} .bb_table_equalcells{table-layout:fixed;width:100%;}
  img{max-width:100%;} .bb_youtube{display:inline-block;position:relative;} .bb_youtube span{position:absolute;left:8px;bottom:8px;background:#000c;color:#fff;padding:2px 6px;font-size:12px;}
  </style></head><body><div id="title"></div><div id="label">Description</div><div id="c"></div></body></html>
  """
}
