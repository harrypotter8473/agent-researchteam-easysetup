"""report_docx — a Markdown report as a Word (.docx) file, with no dependencies.

From hermes-easy-setup's governed report pipeline. No model call, macros or remote
relationships. Headings, paragraphs, lists, **bold** and simple tables are rendered;
anything else stays visible as text. The exact UTF-8 source and where it came from
(path@commit) are kept in custom XML, so the file can be traced back to the repo.

    report_docx.py <report.md> <out.docx> [--source notes/report.md@abc123]
"""
from __future__ import annotations

import hashlib
import io
import json
import re
import zipfile
from xml.sax.saxutils import escape

MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
MAX_BYTES = 2_000_000
W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"


def _xml(text):
    if any(ord(c) < 32 and c not in "\t\n\r" for c in text):
        raise ValueError("ReportXmlControlCharacterRejected")
    # XML normalizes literal CR/CRLF on parsing. Preserve original source bytes
    # through character references so the preview can prove exact fidelity.
    return escape(text).replace('\r', '&#13;')


def _runs(text):
    # Only paired bold markers are interpreted; everything else is retained.
    parts = re.split(r"(\*\*[^*\n]+\*\*)", text)
    return "".join("<w:r>" + ("<w:rPr><w:b/></w:rPr>" if part.startswith("**") and part.endswith("**") else "") +
                   '<w:t xml:space="preserve">' + _xml(part[2:-2] if part.startswith("**") and part.endswith("**") else part) +
                   "</w:t></w:r>" for part in parts if part)


def _paragraph(text, style="Normal"):
    return '<w:p><w:pPr><w:pStyle w:val="' + style + '"/></w:pPr>' + _runs(text) + '</w:p>'


def _table(rows):
    columns = len(rows[0])
    width = 9360 // columns
    borders = ''.join('<w:' + side + ' w:val="single" w:sz="4" w:color="D9D9D9"/>'
                      for side in ('top', 'left', 'bottom', 'right', 'insideH', 'insideV'))
    result = '<w:tbl><w:tblPr><w:tblW w:w="9360" w:type="dxa"/><w:tblBorders>' + borders + '</w:tblBorders><w:tblCellMar><w:top w:w="100" w:type="dxa"/><w:bottom w:w="100" w:type="dxa"/><w:left w:w="100" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr><w:tblGrid>'
    result += ''.join('<w:gridCol w:w="' + str(width) + '"/>' for _ in range(columns)) + '</w:tblGrid>'
    for index, row in enumerate(rows):
        result += '<w:tr>' + ('<w:trPr><w:tblHeader/></w:trPr>' if index == 0 else '')
        for cell in row:
            result += '<w:tc><w:tcPr><w:tcW w:w="' + str(width) + '" w:type="dxa"/><w:vAlign w:val="center"/>' + ('<w:shd w:fill="E7E6E6"/>' if index == 0 else '') + '</w:tcPr>' + _paragraph(cell, 'TableText') + '</w:tc>'
        result += '</w:tr>'
    return result + '</w:tbl>' + _paragraph('')


def build_docx(content, source=""):
    if not isinstance(content, str) or not content.strip() or len(content.encode('utf-8')) > MAX_BYTES:
        raise ValueError("ReportContentRejected")
    digest = hashlib.sha256(content.encode('utf-8')).hexdigest()
    body, lines, index = [], content.splitlines(), 0
    if not lines[0].startswith('# '):
        body.append(_paragraph('Research report', 'Title'))
    while index < len(lines):
        line = lines[index]
        # A table needs a real Markdown separator and consistent cell counts.
        if '|' in line and index + 1 < len(lines) and re.fullmatch(r"\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?\s*", lines[index + 1]):
            cells = lambda value: [cell.strip() for cell in value.strip().strip('|').split('|')]
            rows, end = [cells(line)], index + 2
            while end < len(lines) and '|' in lines[end] and len(cells(lines[end])) == len(rows[0]):
                rows.append(cells(lines[end])); end += 1
            if 1 < len(rows[0]) <= 6:
                body.append(_table(rows)); index = end; continue
        heading = re.match(r'^(#{1,6})\s+(.+)$', line)
        if heading:
            level, text = len(heading[1]), heading[2]
            body.append(_paragraph(text, 'Title' if index == 0 and level == 1 else 'Heading' + str(min(level, 3))))
        elif line.strip():
            body.append(_paragraph(line, 'ListText' if re.match(r'^\s*(?:[-*+] |\d+[.)] )', line) else 'Normal'))
        index += 1
    styles = '<w:styles xmlns:w="' + W + '"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Malgun Gothic" w:hAnsi="Malgun Gothic" w:eastAsia="맑은 고딕"/><w:sz w:val="22"/><w:color w:val="000000"/><w:lang w:val="ko-KR" w:eastAsia="ko-KR"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="300" w:lineRule="auto"/><w:widowControl/></w:pPr></w:pPrDefault></w:docDefaults>'
    for name, size in [('Normal',22), ('Title',36), ('Heading1',30), ('Heading2',26), ('Heading3',24), ('ListText',22), ('TableText',20)]:
        heading = name.startswith('Heading') or name == 'Title'
        styles += '<w:style w:type="paragraph" w:styleId="' + name + '"><w:name w:val="' + name + '"/><w:pPr>' + ('<w:keepNext/><w:spacing w:before="220" w:after="140"/>' if heading else '') + '</w:pPr><w:rPr><w:sz w:val="' + str(size) + '"/><w:color w:val="000000"/>' + ('<w:b/>' if heading else '') + '</w:rPr></w:style>'
    styles += '</w:styles>'
    binding = json.dumps({'source': source, 'sha256': digest}, ensure_ascii=False, sort_keys=True)
    files = {
        '[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>',
        '_rels/.rels': '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
        'word/_rels/document.xml.rels': '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXml" Target="../customXml/item1.xml"/></Relationships>',
        'word/styles.xml': styles,
        'word/document.xml': '<w:document xmlns:w="' + W + '"><w:body>' + ''.join(body) + '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>',
        'customXml/item1.xml': '<report xmlns="urn:hermes:audited-report:v1"><binding>' + _xml(binding) + '</binding><source>' + _xml(content) + '</source></report>',
    }
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, value in files.items():
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0)); info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + value).encode('utf-8'))
    return output.getvalue()


if __name__ == "__main__":
    import argparse
    from pathlib import Path
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("markdown"); ap.add_argument("out"); ap.add_argument("--source", default="")
    a = ap.parse_args()
    text = Path(a.markdown).read_text(encoding="utf-8")
    Path(a.out).write_bytes(build_docx(text, a.source or a.markdown))
    print(f"wrote {a.out}")
