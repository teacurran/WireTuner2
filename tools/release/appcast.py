#!/usr/bin/env python3
"""Adds one release to a Sparkle appcast (docs/spec/releasing.adoc, "The appcast").

    appcast.py --base BASE.xml|'' --out appcast.xml --feed URL --channel beta
               --version 0.1.0 --build 12 --url https://.../WireTuner-2026.09.28-001.zip --length N
               [--signature EDSIG] --minimum-system 15.0 --notes NOTES.md [--unsigned]

The items already in BASE are kept, newest build first.  The build number must be greater than
every build BASE holds (Sparkle orders updates by CFBundleVersion); the same build replaces its
item (a re-run of one release).  The release notes are Markdown, rendered to the small HTML
subset Sparkle's release-notes view shows: headings, paragraphs, lists, emphasis, code, links.
"""

import argparse
import email.utils
import html
import re
import sys
import time
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", DC)
UNSIGNED_MARK = "UNSIGNED TEST APPCAST: not signed with the Sparkle key; never publish it."


def inline(text):
    """Markdown inline spans -> HTML, on escaped text."""
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*([^*]+)\*(?![\w*])", r"<em>\1</em>", text)
    text = re.sub(r"(?<![\w_])_([^_]+)_(?![\w_])", r"<em>\1</em>", text)
    text = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)",
                  lambda m: '<a href="%s">%s</a>' % (m.group(2).replace('"', "%22"), m.group(1)), text)
    return text


def markdown_to_html(source):
    """A deliberately small Markdown: #-headings, blank-line paragraphs, - / * / 1. lists."""
    out, paragraph, list_tag = [], [], None

    def flush_paragraph():
        if paragraph:
            out.append("<p>%s</p>" % inline(" ".join(paragraph)))
            paragraph.clear()

    def close_list():
        nonlocal list_tag
        if list_tag:
            out.append("</%s>" % list_tag)
            list_tag = None

    for raw in source.splitlines():
        line = raw.strip()
        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        bullet = re.match(r"^[-*]\s+(.*)$", line)
        numbered = re.match(r"^\d+[.)]\s+(.*)$", line)
        if not line:
            flush_paragraph()
            close_list()
        elif heading:
            flush_paragraph()
            close_list()
            level = min(len(heading.group(1)) + 1, 6)  # the item title is the h1
            out.append("<h%d>%s</h%d>" % (level, inline(heading.group(2)), level))
        elif bullet or numbered:
            flush_paragraph()
            tag = "ul" if bullet else "ol"
            if list_tag != tag:
                close_list()
                out.append("<%s>" % tag)
                list_tag = tag
            out.append("<li>%s</li>" % inline((bullet or numbered).group(1)))
        elif list_tag and raw[:1] in (" ", "\t") and out[-1].endswith("</li>"):
            out[-1] = out[-1][: -len("</li>")] + " " + inline(line) + "</li>"
        else:
            close_list()
            paragraph.append(line)
    flush_paragraph()
    close_list()
    return "\n".join(out)


def item_build(item):
    value = item.findtext("{%s}version" % SPARKLE)
    if value is None:
        enclosure = item.find("enclosure")
        value = enclosure.get("{%s}version" % SPARKLE) if enclosure is not None else None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def main(argv):
    parser = argparse.ArgumentParser()
    for name in ("base", "out", "feed", "channel", "version", "url", "minimum-system", "notes"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--length", type=int, required=True)
    parser.add_argument("--signature", default="")
    parser.add_argument("--unsigned", action="store_true")
    parser.add_argument("--pub-date", default=None, help="RFC 2822; default now")
    args = parser.parse_args(argv)

    if args.base:
        tree = ET.parse(args.base)
        rss = tree.getroot()
        channel = rss.find("channel")
        if rss.tag != "rss" or channel is None:
            sys.exit("appcast: %s is not an RSS appcast" % args.base)
    else:
        rss = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = "WireTuner (%s)" % args.channel
        ET.SubElement(channel, "link").text = args.feed
        ET.SubElement(channel, "description").text = "WireTuner updates, %s channel" % args.channel
        ET.SubElement(channel, "language").text = "en"

    items = channel.findall("item")
    for item in items:
        build = item_build(item)
        if build == args.build:
            channel.remove(item)
        elif build is not None and build > args.build:
            sys.exit("appcast: build %d is not newer than build %d, already in the appcast "
                     "(make bump-build)" % (args.build, build))

    with open(args.notes, encoding="utf-8") as handle:
        notes = markdown_to_html(handle.read())

    item = ET.Element("item")
    ET.SubElement(item, "title").text = "WireTuner %s (%d)" % (args.version, args.build)
    ET.SubElement(item, "pubDate").text = args.pub_date or email.utils.formatdate(time.time(), usegmt=True)
    ET.SubElement(item, "{%s}version" % SPARKLE).text = str(args.build)
    ET.SubElement(item, "{%s}shortVersionString" % SPARKLE).text = args.version
    ET.SubElement(item, "{%s}minimumSystemVersion" % SPARKLE).text = args.minimum_system
    ET.SubElement(item, "description").text = notes
    enclosure = {"url": args.url, "length": str(args.length), "type": "application/octet-stream"}
    if args.signature:
        enclosure["{%s}edSignature" % SPARKLE] = args.signature
    ET.SubElement(item, "enclosure", enclosure)

    # Newest first: after the channel's own elements, before the older items.
    position = next((i for i, child in enumerate(list(channel)) if child.tag == "item"), len(channel))
    channel.insert(position, item)

    ET.indent(rss, space="  ")
    body = ET.tostring(rss, encoding="unicode")
    # The parser drops comments, so the mark is only ever this run's.
    mark = "<!-- %s -->\n" % UNSIGNED_MARK if args.unsigned else ""
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write('<?xml version="1.0" encoding="utf-8"?>\n' + mark + body + "\n")


if __name__ == "__main__":
    main(sys.argv[1:])
