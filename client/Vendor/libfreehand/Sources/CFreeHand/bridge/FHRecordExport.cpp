/* -*- Mode: C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/*
 * This file is part of WireTuner's build of libfreehand.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

// The FreeHand importer's bridge (docs/spec/decisions.adoc D-083).  libfreehand's FHParser reads
// the file into an FHCollector; libfreehand would then draw the collected records through
// librevenge, which flattens what WireTuner can keep live (clipping groups become SVG images,
// tiled fills bitmaps, symbols and blends plain groups, named and spot colours RGB).  This file
// instead writes every collected record out as one JSON document -- ids, lists, transforms, path
// segments, styles, colours, text, images -- for WTInterchange's FreeHandImporter to convert.
// It is a friend of FHParser and FHCollector (patches 0002/0003 in tools/freehand/patches).

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include <librevenge/librevenge.h>
#include <librevenge-stream/librevenge-stream.h>

#include "RVNGMemoryStream.h"
#include "FHCollector.h"
#include "FHInternalStream.h"
#include "FHParser.h"
#include "libfreehand_utils.h"

#include "CFreeHand.h"

namespace libfreehand
{

namespace
{

// A small JSON writer: objects and arrays with automatic commas.
class JSONWriter
{
public:
  JSONWriter() : m_out(), m_first(true) {}

  void beginObject()
  {
    separator();
    m_out += '{';
    m_first = true;
  }
  void endObject()
  {
    m_out += '}';
    m_first = false;
  }
  void beginArray()
  {
    separator();
    m_out += '[';
    m_first = true;
  }
  void endArray()
  {
    m_out += ']';
    m_first = false;
  }
  void key(const std::string &name)
  {
    separator();
    quoted(name);
    m_out += ':';
    m_first = true;
  }
  void key(unsigned id)
  {
    key(std::to_string(id));
  }
  void number(double value)
  {
    separator();
    if (!std::isfinite(value))
      value = 0;
    char buffer[40];
    snprintf(buffer, sizeof(buffer), "%.17g", value);
    m_out += buffer;
  }
  void integer(long long value)
  {
    separator();
    m_out += std::to_string(value);
  }
  void boolean(bool value)
  {
    separator();
    m_out += value ? "true" : "false";
  }
  void null()
  {
    separator();
    m_out += "null";
  }
  void string(const std::string &value)
  {
    separator();
    quoted(value);
  }
  void quoted(const std::string &value)
  {
    m_out += '"';
    for (unsigned char c : value)
    {
      switch (c)
      {
      case '"':
        m_out += "\\\"";
        break;
      case '\\':
        m_out += "\\\\";
        break;
      case '\n':
        m_out += "\\n";
        break;
      case '\r':
        m_out += "\\r";
        break;
      case '\t':
        m_out += "\\t";
        break;
      default:
        if (c < 0x20)
        {
          char buffer[8];
          snprintf(buffer, sizeof(buffer), "\\u%04x", c);
          m_out += buffer;
        }
        else
          m_out += char(c);
      }
    }
    m_out += '"';
  }
  void hex(const unsigned char *bytes, size_t count)
  {
    static const char digits[] = "0123456789abcdef";
    separator();
    m_out += '"';
    for (size_t i = 0; i < count; ++i)
    {
      m_out += digits[bytes[i] >> 4];
      m_out += digits[bytes[i] & 15];
    }
    m_out += '"';
  }

  // Shorthands for "key": value.
  void field(const std::string &name, double value)
  {
    key(name);
    number(value);
  }
  void field(const std::string &name, unsigned value)
  {
    key(name);
    integer(value);
  }
  void field(const std::string &name, int value)
  {
    key(name);
    integer(value);
  }
  void field(const std::string &name, bool value)
  {
    key(name);
    boolean(value);
  }
  void field(const std::string &name, const std::string &value)
  {
    key(name);
    string(value);
  }
  void idArray(const std::string &name, const std::vector<unsigned> &ids)
  {
    key(name);
    beginArray();
    for (unsigned id : ids)
      integer(id);
    endArray();
  }
  void doubleArray(const std::string &name, const std::vector<double> &values)
  {
    key(name);
    beginArray();
    for (double value : values)
      number(value);
    endArray();
  }

  std::string &output()
  {
    return m_out;
  }

private:
  void separator()
  {
    if (!m_first)
      m_out += ',';
    m_first = false;
  }

  std::string m_out;
  bool m_first;
};

// The UTF-8 of a librevenge string.
std::string text(const librevenge::RVNGString &value)
{
  return value.cstr() ? std::string(value.cstr()) : std::string();
}

// A transform as its six coefficients, in libfreehand's field order.
void writeTransform(JSONWriter &json, const FHTransform &transform)
{
  json.beginArray();
  json.number(transform.m_m11);
  json.number(transform.m_m21);
  json.number(transform.m_m12);
  json.number(transform.m_m22);
  json.number(transform.m_m13);
  json.number(transform.m_m23);
  json.endArray();
}

double propertyDouble(const librevenge::RVNGPropertyList &list, const char *name)
{
  const librevenge::RVNGProperty *property = list[name];
  return property ? property->getDouble() : 0.0;
}

// A path's segments as [action, numbers...], through FHPath::writeOut (coordinates in inches).
void writePath(JSONWriter &json, const FHPath &path)
{
  json.beginObject();
  json.field("style", path.getGraphicStyleId());
  json.field("xform", path.getXFormId());
  json.field("evenOdd", path.getEvenOdd());
  json.field("closed", path.isClosed());
  librevenge::RVNGPropertyListVector segments;
  path.writeOut(segments);
  json.key("d");
  json.beginArray();
  for (unsigned long i = 0; i < segments.count(); ++i)
  {
    const librevenge::RVNGPropertyList &segment = segments[i];
    const librevenge::RVNGProperty *action = segment["librevenge:path-action"];
    if (!action)
      continue;
    const std::string kind = text(action->getStr());
    json.beginArray();
    json.string(kind);
    if (kind == "C")
    {
      json.number(propertyDouble(segment, "svg:x1"));
      json.number(propertyDouble(segment, "svg:y1"));
      json.number(propertyDouble(segment, "svg:x2"));
      json.number(propertyDouble(segment, "svg:y2"));
    }
    else if (kind == "Q")
    {
      json.number(propertyDouble(segment, "svg:x1"));
      json.number(propertyDouble(segment, "svg:y1"));
    }
    else if (kind == "A")
    {
      json.number(propertyDouble(segment, "svg:rx"));
      json.number(propertyDouble(segment, "svg:ry"));
      json.number(propertyDouble(segment, "librevenge:rotate"));
      const librevenge::RVNGProperty *large = segment["librevenge:large-arc"];
      const librevenge::RVNGProperty *sweep = segment["librevenge:sweep"];
      json.number(large ? large->getInt() : 0);
      json.number(sweep ? sweep->getInt() : 0);
    }
    if (kind != "Z")
    {
      json.number(propertyDouble(segment, "svg:x"));
      json.number(propertyDouble(segment, "svg:y"));
    }
    json.endArray();
  }
  json.endArray();
  json.endObject();
}

void writeGroup(JSONWriter &json, const FHGroup &group)
{
  json.beginObject();
  json.field("style", group.m_graphicStyleId);
  json.field("elements", group.m_elementsId);
  json.field("xform", group.m_xFormId);
  json.endObject();
}

void writeIdMap(JSONWriter &json, const std::map<unsigned, unsigned> &map)
{
  json.beginObject();
  for (const auto &entry : map)
  {
    json.key(entry.first);
    json.integer(entry.second);
  }
  json.endObject();
}

void writeDoubleMap(JSONWriter &json, const std::map<unsigned, double> &map)
{
  json.beginObject();
  for (const auto &entry : map)
  {
    json.key(entry.first);
    json.number(entry.second);
  }
  json.endObject();
}

// FreeHandDocument.cpp's findAGD: the AGD header at the start, or inside the 0x1c records a
// FreeHand 10 or MX file begins with.  Leaves the stream at the header.
bool findAGD(librevenge::RVNGInputStream *input)
{
  unsigned agd = readU32(input);
  input->seek(-4, librevenge::RVNG_SEEK_CUR);
  if (((agd >> 24) & 0xff) == 'A' && ((agd >> 16) & 0xff) == 'G' && ((agd >> 8) & 0xff) == 'D')
    return true;
  if (((agd >> 24) & 0xff) == 'F' && ((agd >> 16) & 0xff) == 'H' && ((agd >> 8) & 0xff) == '3')
    return true;
  while (!input->isEnd())
  {
    if (0x1c != readU8(input))
      return false;
    unsigned short opcode = readU16(input);
    unsigned char flag = readU8(input);
    unsigned length = readU8(input);
    if (0x80 == flag)
    {
      if (4 != length)
        return false;
      length = readU32(input);
      if (0x080a == opcode)
      {
        agd = readU32(input);
        input->seek(-4, librevenge::RVNG_SEEK_CUR);
        if (((agd >> 24) & 0xff) == 'A' && ((agd >> 16) & 0xff) == 'G' && ((agd >> 8) & 0xff) == 'D')
          return true;
      }
    }
    input->seek(length, librevenge::RVNG_SEEK_CUR);
  }
  return false;
}

} // anonymous namespace

class FHRecordExporter
{
public:
  // Parses `input` and writes the records; false when it is not a FreeHand document.
  static bool run(librevenge::RVNGInputStream *input, std::string &out)
  {
    FHParser parser;
    FHCollector collector;
    bool complete = true;
    try
    {
      input->seek(0, librevenge::RVNG_SEEK_SET);
      if (!findAGD(input))
        return false;
      // FHParser::parse up to the drawing, which the importer does instead.
      long dataOffset = input->tell();
      unsigned agd = readU32(input);
      if (((agd >> 24) & 0xff) == 'A' && ((agd >> 16) & 0xff) == 'G' && ((agd >> 8) & 0xff) == 'D')
        parser.m_version = int(agd & 0xff) - 0x30 + 5;
      else if (((agd >> 24) & 0xff) == 'F' && ((agd >> 16) & 0xff) == 'H' && ((agd >> 8) & 0xff) == '3')
        parser.m_version = 3;
      else
        return false;
      input->seek(4, librevenge::RVNG_SEEK_CUR);
      unsigned dataLength = readU32(input);
      input->seek(dataOffset + dataLength, librevenge::RVNG_SEEK_SET);
      parser.parseDictionary(input);
      parser.parseRecordList(input);
      input->seek(dataOffset + 12, librevenge::RVNG_SEEK_SET);
      FHInternalStream dataStream(input, dataLength - 12, parser.m_version >= 9);
      dataStream.seek(0, librevenge::RVNG_SEEK_SET);
      try
      {
        parser.parseDocument(&dataStream, &collector);
      }
      catch (...)
      {
        complete = false;
        collector.collectPageInfo(parser.m_pageInfo);
      }
    }
    catch (...)
    {
      if (parser.m_version < 0)
        return false;
      complete = false;
    }
    if (parser.m_currentRecord < parser.m_records.size())
      complete = false;
    JSONWriter json;
    write(json, parser, collector, complete);
    out.swap(json.output());
    return true;
  }

private:
  static void write(JSONWriter &json, const FHParser &parser, const FHCollector &c, bool complete)
  {
    json.beginObject();
    json.field("version", parser.m_version);
    json.field("complete", complete);

    // What the file holds, by record type, and where reading stopped.
    json.field("recordCount", unsigned(parser.m_records.size()));
    json.field("recordsRead", unsigned(parser.m_currentRecord));
    json.key("recordTypes");
    json.beginObject();
    std::map<std::string, unsigned> counts;
    for (unsigned short id : parser.m_records)
    {
      auto name = parser.m_dictionaryNames.find(id);
      counts[name != parser.m_dictionaryNames.end() ? name->second : std::string("?")] += 1;
    }
    for (const auto &entry : counts)
    {
      json.key(entry.first);
      json.integer(entry.second);
    }
    json.endObject();
    if (parser.m_currentRecord < parser.m_records.size())
    {
      auto name = parser.m_dictionaryNames.find(parser.m_records[parser.m_currentRecord]);
      json.field("stoppedAt", name != parser.m_dictionaryNames.end() ? name->second : std::string("?"));
    }

    json.key("pageInfo");
    json.beginArray();
    json.number(c.m_pageInfo.m_minX);
    json.number(c.m_pageInfo.m_minY);
    json.number(c.m_pageInfo.m_maxX);
    json.number(c.m_pageInfo.m_maxY);
    json.endArray();
    json.key("pages");
    json.beginArray();
    for (const FHPageInfo &page : parser.m_pages)
    {
      json.beginArray();
      json.number(page.m_minX);
      json.number(page.m_minY);
      json.number(page.m_maxX);
      json.number(page.m_maxY);
      json.endArray();
    }
    json.endArray();
    json.key("tailPageInfo");
    json.beginArray();
    json.number(c.m_fhTail.m_pageInfo.m_minX);
    json.number(c.m_fhTail.m_pageInfo.m_minY);
    json.number(c.m_fhTail.m_pageInfo.m_maxX);
    json.number(c.m_fhTail.m_pageInfo.m_maxY);
    json.endArray();
    json.field("tailBlock", c.m_fhTail.m_blockId);
    json.field("block", c.m_block.first);
    json.field("layerList", c.m_block.second.m_layerListId);
    json.field("strokeName", c.m_strokeId);
    json.field("fillName", c.m_fillId);
    json.field("contentsName", c.m_contentId);

    json.key("transforms");
    json.beginObject();
    for (const auto &entry : c.m_transforms)
    {
      json.key(entry.first);
      writeTransform(json, entry.second);
    }
    json.endObject();

    json.key("paths");
    json.beginObject();
    for (const auto &entry : c.m_paths)
    {
      json.key(entry.first);
      writePath(json, entry.second);
    }
    json.endObject();

    json.key("arrowPaths");
    json.beginObject();
    for (const auto &entry : c.m_arrowPaths)
    {
      json.key(entry.first);
      writePath(json, entry.second);
    }
    json.endObject();

    json.key("strings");
    json.beginObject();
    for (const auto &entry : c.m_strings)
    {
      json.key(entry.first);
      json.string(text(entry.second));
    }
    json.endObject();

    json.key("names");
    json.beginObject();
    for (const auto &entry : c.m_names)
    {
      json.key(text(entry.first));
      json.integer(entry.second);
    }
    json.endObject();

    json.key("lists");
    json.beginObject();
    for (const auto &entry : c.m_lists)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("type", entry.second.m_listType);
      json.idArray("elements", entry.second.m_elements);
      json.endObject();
    }
    json.endObject();

    json.key("layers");
    json.beginObject();
    for (const auto &entry : c.m_layers)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("style", entry.second.m_graphicStyleId);
      json.field("elements", entry.second.m_elementsId);
      json.field("visibility", entry.second.m_visibility);
      json.field("name", entry.second.m_nameId);
      json.endObject();
    }
    json.endObject();

    json.key("groups");
    json.beginObject();
    for (const auto &entry : c.m_groups)
    {
      json.key(entry.first);
      writeGroup(json, entry.second);
    }
    json.endObject();

    json.key("clipGroups");
    json.beginObject();
    for (const auto &entry : c.m_clipGroups)
    {
      json.key(entry.first);
      writeGroup(json, entry.second);
    }
    json.endObject();

    json.key("compositePaths");
    json.beginObject();
    for (const auto &entry : c.m_compositePaths)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("style", entry.second.m_graphicStyleId);
      json.field("elements", entry.second.m_elementsId);
      json.endObject();
    }
    json.endObject();

    json.key("pathTexts");
    json.beginObject();
    for (const auto &entry : c.m_pathTexts)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("elements", entry.second.m_elementsId);
      json.field("layer", entry.second.m_layerId);
      json.field("displayText", entry.second.m_displayTextId);
      json.field("shape", entry.second.m_shapeId);
      json.field("textSize", entry.second.m_textSize);
      json.endObject();
    }
    json.endObject();

    json.key("tStrings");
    json.beginObject();
    for (const auto &entry : c.m_tStrings)
    {
      json.key(entry.first);
      json.beginArray();
      for (unsigned id : entry.second)
        json.integer(id);
      json.endArray();
    }
    json.endObject();

    json.key("fonts");
    json.beginObject();
    for (const auto &entry : c.m_fonts)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("name", entry.second.m_fontNameId);
      json.field("style", entry.second.m_fontStyle);
      json.field("size", entry.second.m_fontSize);
      json.endObject();
    }
    json.endObject();

    json.key("tEffects");
    json.beginObject();
    for (const auto &entry : c.m_tEffects)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("name", entry.second.m_nameId);
      json.field("shortName", entry.second.m_shortNameId);
      json.key("colors");
      json.beginArray();
      json.integer(entry.second.m_colorId[0]);
      json.integer(entry.second.m_colorId[1]);
      json.endArray();
      json.endObject();
    }
    json.endObject();

    json.key("paragraphs");
    json.beginObject();
    for (const auto &entry : c.m_paragraphs)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("paraStyle", entry.second.m_paraStyleId);
      json.field("textBlok", entry.second.m_textBlokId);
      json.key("charStyles");
      json.beginArray();
      for (const auto &run : entry.second.m_charStyleIds)
      {
        json.beginArray();
        json.integer(run.first);
        json.integer(run.second);
        json.endArray();
      }
      json.endArray();
      json.endObject();
    }
    json.endObject();

    json.key("tabs");
    json.beginObject();
    for (const auto &entry : c.m_tabs)
    {
      json.key(entry.first);
      json.beginArray();
      for (const FHTab &tab : entry.second)
      {
        json.beginArray();
        json.integer(tab.m_type);
        json.number(tab.m_position);
        json.endArray();
      }
      json.endArray();
    }
    json.endObject();

    json.key("textBloks");
    json.beginObject();
    for (const auto &entry : c.m_textBloks)
    {
      json.key(entry.first);
      json.beginArray();
      for (unsigned short unit : entry.second)
        json.integer(unit);
      json.endArray();
    }
    json.endObject();

    json.key("textObjects");
    json.beginObject();
    for (const auto &entry : c.m_textObjects)
    {
      const FHTextObject &t = entry.second;
      json.key(entry.first);
      json.beginObject();
      json.field("style", t.m_graphicStyleId);
      json.field("xform", t.m_xFormId);
      json.field("tString", t.m_tStringId);
      json.field("vmpObj", t.m_vmpObjId);
      json.field("path", t.m_pathId);
      json.field("startX", t.m_startX);
      json.field("startY", t.m_startY);
      json.field("width", t.m_width);
      json.field("height", t.m_height);
      json.field("beginPos", t.m_beginPos);
      json.field("endPos", t.m_endPos);
      json.field("colNum", t.m_colNum);
      json.field("rowNum", t.m_rowNum);
      json.field("colSep", t.m_colSep);
      json.field("rowSep", t.m_rowSep);
      json.field("rowBreakFirst", t.m_rowBreakFirst);
      json.endObject();
    }
    json.endObject();

    json.key("charProperties");
    json.beginObject();
    for (const auto &entry : c.m_charProperties)
    {
      const FHCharProperties &p = entry.second;
      json.key(entry.first);
      json.beginObject();
      json.field("textColor", p.m_textColorId);
      json.field("fontSize", p.m_fontSize);
      json.field("fontName", p.m_fontNameId);
      json.field("font", p.m_fontId);
      json.field("tEffect", p.m_tEffectId);
      json.key("values");
      writeDoubleMap(json, p.m_idToDoubleMap);
      json.endObject();
    }
    json.endObject();

    json.key("paragraphProperties");
    json.beginObject();
    for (const auto &entry : c.m_paragraphProperties)
    {
      json.key(entry.first);
      json.beginObject();
      json.key("ints");
      writeIdMap(json, entry.second.m_idToIntMap);
      json.key("values");
      writeDoubleMap(json, entry.second.m_idToDoubleMap);
      json.key("zones");
      writeIdMap(json, entry.second.m_idToZoneIdMap);
      json.endObject();
    }
    json.endObject();

    json.key("rgbColors");
    json.beginObject();
    for (const auto &entry : c.m_rgbColors)
    {
      json.key(entry.first);
      json.beginArray();
      json.integer(entry.second.m_red);
      json.integer(entry.second.m_green);
      json.integer(entry.second.m_blue);
      json.endArray();
    }
    json.endObject();

    json.key("colorRecords");
    json.beginObject();
    for (const auto &entry : c.m_colorRecords)
    {
      const FHColorRecord &r = entry.second;
      json.key(entry.first);
      json.beginObject();
      json.field("kind", r.m_kind);
      json.field("variant", r.m_variant);
      json.field("name", r.m_nameId);
      json.field("other", r.m_otherId);
      if (r.m_hasCMYK)
      {
        json.key("cmyk");
        json.beginArray();
        json.integer(r.m_cmyk.m_cyan);
        json.integer(r.m_cmyk.m_magenta);
        json.integer(r.m_cmyk.m_yellow);
        json.integer(r.m_cmyk.m_black);
        json.endArray();
      }
      json.key("raw");
      json.hex(r.m_raw.data(), r.m_raw.size());
      json.endObject();
    }
    json.endObject();

    json.key("tints");
    json.beginObject();
    for (const auto &entry : c.m_tints)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("base", entry.second.m_baseColorId);
      json.field("tint", unsigned(entry.second.m_tint));
      json.endObject();
    }
    json.endObject();

    json.key("basicFills");
    json.beginObject();
    for (const auto &entry : c.m_basicFills)
    {
      json.key(entry.first);
      json.integer(entry.second.m_colorId);
    }
    json.endObject();

    json.key("propertyLists");
    json.beginObject();
    for (const auto &entry : c.m_propertyLists)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("parent", entry.second.m_parentId);
      json.key("elements");
      writeIdMap(json, entry.second.m_elements);
      json.endObject();
    }
    json.endObject();

    json.key("basicLines");
    json.beginObject();
    for (const auto &entry : c.m_basicLines)
    {
      const FHBasicLine &l = entry.second;
      json.key(entry.first);
      json.beginObject();
      json.field("color", l.m_colorId);
      json.field("pattern", l.m_linePatternId);
      json.field("startArrow", l.m_startArrowId);
      json.field("endArrow", l.m_endArrowId);
      json.field("miter", l.m_mitter);
      json.field("width", l.m_width);
      json.endObject();
    }
    json.endObject();

    json.key("customProcs");
    json.beginObject();
    for (const auto &entry : c.m_customProcs)
    {
      json.key(entry.first);
      json.beginObject();
      json.idArray("ids", entry.second.m_ids);
      json.doubleArray("widths", entry.second.m_widths);
      json.doubleArray("params", entry.second.m_params);
      json.doubleArray("angles", entry.second.m_angles);
      json.endObject();
    }
    json.endObject();

    json.key("patternLines");
    json.beginObject();
    for (const auto &entry : c.m_patternLines)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("color", entry.second.m_colorId);
      json.field("percent", entry.second.m_percentPattern);
      json.field("miter", entry.second.m_mitter);
      json.field("width", entry.second.m_width);
      json.endObject();
    }
    json.endObject();

    json.key("displayTexts");
    json.beginObject();
    for (const auto &entry : c.m_displayTexts)
    {
      const FHDisplayText &d = entry.second;
      json.key(entry.first);
      json.beginObject();
      json.field("style", d.m_graphicStyleId);
      json.field("xform", d.m_xFormId);
      json.field("startX", d.m_startX);
      json.field("startY", d.m_startY);
      json.field("width", d.m_width);
      json.field("height", d.m_height);
      json.field("justify", d.m_justify);
      json.key("charProps");
      json.beginArray();
      for (const FH3CharProperties &p : d.m_charProps)
      {
        json.beginObject();
        json.field("offset", p.m_offset);
        json.field("fontName", p.m_fontNameId);
        json.field("fontSize", p.m_fontSize);
        json.field("fontStyle", p.m_fontStyle);
        json.field("fontColor", p.m_fontColorId);
        json.field("textEffs", p.m_textEffsId);
        json.field("leading", p.m_leading);
        json.field("letterSpacing", p.m_letterSpacing);
        json.field("wordSpacing", p.m_wordSpacing);
        json.field("horizontalScale", p.m_horizontalScale);
        json.field("baselineShift", p.m_baselineShift);
        json.endObject();
      }
      json.endArray();
      json.key("paraOffsets");
      json.beginArray();
      for (const FH3ParaProperties &p : d.m_paraProps)
        json.integer(p.m_offset);
      json.endArray();
      json.key("characters");
      json.hex(d.m_characters.data(), d.m_characters.size());
      json.endObject();
    }
    json.endObject();

    json.key("graphicStyles");
    json.beginObject();
    for (const auto &entry : c.m_graphicStyles)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("parent", entry.second.m_parentId);
      json.field("attr", entry.second.m_attrId);
      json.key("elements");
      writeIdMap(json, entry.second.m_elements);
      json.endObject();
    }
    json.endObject();

    json.key("attributeHolders");
    json.beginObject();
    for (const auto &entry : c.m_attributeHolders)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("parent", entry.second.m_parentId);
      json.field("attr", entry.second.m_attrId);
      json.endObject();
    }
    json.endObject();

    json.key("filterAttributeHolders");
    json.beginObject();
    for (const auto &entry : c.m_filterAttributeHolders)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("parent", entry.second.m_parentId);
      json.field("filter", entry.second.m_filterId);
      json.field("style", entry.second.m_graphicStyleId);
      json.endObject();
    }
    json.endObject();

    json.key("data");
    json.beginObject();
    for (const auto &entry : c.m_data)
    {
      json.key(entry.first);
      json.hex(entry.second.getDataBuffer(), entry.second.size());
    }
    json.endObject();

    json.key("dataLists");
    json.beginObject();
    for (const auto &entry : c.m_dataLists)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("size", entry.second.m_dataSize);
      json.idArray("elements", entry.second.m_elements);
      json.endObject();
    }
    json.endObject();

    json.key("images");
    json.beginObject();
    for (const auto &entry : c.m_images)
    {
      const FHImageImport &i = entry.second;
      json.key(entry.first);
      json.beginObject();
      json.field("style", i.m_graphicStyleId);
      json.field("dataList", i.m_dataListId);
      json.field("xform", i.m_xFormId);
      json.field("startX", i.m_startX);
      json.field("startY", i.m_startY);
      json.field("width", i.m_width);
      json.field("height", i.m_height);
      json.field("format", text(i.m_format));
      json.endObject();
    }
    json.endObject();

    json.key("multiColorLists");
    json.beginObject();
    for (const auto &entry : c.m_multiColorLists)
    {
      json.key(entry.first);
      json.beginArray();
      for (const FHColorStop &stop : entry.second)
      {
        json.beginArray();
        json.integer(stop.m_colorId);
        json.number(stop.m_position);
        json.endArray();
      }
      json.endArray();
    }
    json.endObject();

    json.key("linearFills");
    json.beginObject();
    for (const auto &entry : c.m_linearFills)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("color1", entry.second.m_color1Id);
      json.field("color2", entry.second.m_color2Id);
      json.field("angle", entry.second.m_angle);
      json.field("multiColorList", entry.second.m_multiColorListId);
      json.endObject();
    }
    json.endObject();

    json.key("radialFills");
    json.beginObject();
    for (const auto &entry : c.m_radialFills)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("color1", entry.second.m_color1Id);
      json.field("color2", entry.second.m_color2Id);
      json.field("cx", entry.second.m_cx);
      json.field("cy", entry.second.m_cy);
      json.field("multiColorList", entry.second.m_multiColorListId);
      json.endObject();
    }
    json.endObject();

    json.key("lensFills");
    json.beginObject();
    for (const auto &entry : c.m_lensFills)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("color", entry.second.m_colorId);
      json.field("value", entry.second.m_value);
      json.field("mode", entry.second.m_mode);
      json.endObject();
    }
    json.endObject();

    json.key("tileFills");
    json.beginObject();
    for (const auto &entry : c.m_tileFills)
    {
      const FHTileFill &t = entry.second;
      json.key(entry.first);
      json.beginObject();
      json.field("xform", t.m_xFormId);
      json.field("group", t.m_groupId);
      json.field("scaleX", t.m_scaleX);
      json.field("scaleY", t.m_scaleY);
      json.field("offsetX", t.m_offsetX);
      json.field("offsetY", t.m_offsetY);
      json.field("angle", t.m_angle);
      json.endObject();
    }
    json.endObject();

    json.key("patternFills");
    json.beginObject();
    for (const auto &entry : c.m_patternFills)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("color", entry.second.m_colorId);
      json.key("pattern");
      json.hex(entry.second.m_pattern.data(), entry.second.m_pattern.size());
      json.endObject();
    }
    json.endObject();

    json.key("linePatterns");
    json.beginObject();
    for (const auto &entry : c.m_linePatterns)
    {
      json.key(entry.first);
      json.beginArray();
      for (double dash : entry.second.m_dashes)
        json.number(dash);
      json.endArray();
    }
    json.endObject();

    json.key("newBlends");
    json.beginObject();
    for (const auto &entry : c.m_newBlends)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("style", entry.second.m_graphicStyleId);
      json.field("parent", entry.second.m_parentId);
      json.field("list1", entry.second.m_list1Id);
      json.field("list2", entry.second.m_list2Id);
      json.field("list3", entry.second.m_list3Id);
      json.endObject();
    }
    json.endObject();

    json.key("opacityFilters");
    writeDoubleMap(json, c.m_opacityFilters);

    json.key("shadowFilters");
    json.beginObject();
    for (const auto &entry : c.m_shadowFilters)
    {
      const FWShadowFilter &s = entry.second;
      json.key(entry.first);
      json.beginObject();
      json.field("color", s.m_colorId);
      json.field("knockOut", s.m_knockOut);
      json.field("inner", s.m_inner);
      json.field("distribution", s.m_distribution);
      json.field("opacity", s.m_opacity);
      json.field("smoothness", s.m_smoothness);
      json.field("angle", s.m_angle);
      json.endObject();
    }
    json.endObject();

    json.key("glowFilters");
    json.beginObject();
    for (const auto &entry : c.m_glowFilters)
    {
      const FWGlowFilter &g = entry.second;
      json.key(entry.first);
      json.beginObject();
      json.field("color", g.m_colorId);
      json.field("inner", g.m_inner);
      json.field("width", g.m_width);
      json.field("opacity", g.m_opacity);
      json.field("smoothness", g.m_smoothness);
      json.field("distribution", g.m_distribution);
      json.endObject();
    }
    json.endObject();

    json.key("symbolClasses");
    json.beginObject();
    for (const auto &entry : c.m_symbolClasses)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("name", entry.second.m_nameId);
      json.field("group", entry.second.m_groupId);
      json.field("dateTime", entry.second.m_dateTimeId);
      json.field("library", entry.second.m_symbolLibraryId);
      json.field("list", entry.second.m_listId);
      json.endObject();
    }
    json.endObject();

    json.key("symbolInstances");
    json.beginObject();
    for (const auto &entry : c.m_symbolInstances)
    {
      json.key(entry.first);
      json.beginObject();
      json.field("style", entry.second.m_graphicStyleId);
      json.field("parent", entry.second.m_parentId);
      json.field("symbolClass", entry.second.m_symbolClassId);
      json.key("xform");
      writeTransform(json, entry.second.m_xForm);
      json.endObject();
    }
    json.endObject();

    json.endObject();
  }
};

} // namespace libfreehand

extern "C" int wt_freehand_is_supported(const unsigned char *data, size_t size)
{
  if (!data || size < 4)
    return 0;
  librevenge::RVNGMemoryInputStream input(const_cast<unsigned char *>(data), size);
  try
  {
    return libfreehand::findAGD(&input) ? 1 : 0;
  }
  catch (...)
  {
    return 0;
  }
}

extern "C" char *wt_freehand_export_records(const unsigned char *data, size_t size, size_t *length)
{
  if (length)
    *length = 0;
  if (!data || size < 4)
    return nullptr;
  librevenge::RVNGMemoryInputStream input(const_cast<unsigned char *>(data), size);
  std::string json;
  bool ok = false;
  try
  {
    ok = libfreehand::FHRecordExporter::run(&input, json);
  }
  catch (...)
  {
    ok = false;
  }
  if (!ok)
    return nullptr;
  char *result = static_cast<char *>(std::malloc(json.size() + 1));
  if (!result)
    return nullptr;
  std::memcpy(result, json.data(), json.size());
  result[json.size()] = 0;
  if (length)
    *length = json.size();
  return result;
}

extern "C" void wt_freehand_free(char *json)
{
  std::free(json);
}
