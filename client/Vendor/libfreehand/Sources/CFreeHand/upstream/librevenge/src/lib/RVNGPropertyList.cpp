/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: t; c-basic-offset: 4 -*- */
/* librevenge
 * Version: MPL 2.0 / LGPLv2.1+
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Major Contributor(s):
 * Copyright (C) 2004 William Lachance (wrlach@gmail.com)
 * Copyright (C) 2005 Net Integration Technologies (http://www.net-itech.com)
 * Copyright (C) 2006 Fridrich Strba (fridrich.strba@bluewin.ch)
 *
 * For minor contributions see the git repository.
 *
 * Alternatively, the contents of this file may be used under the terms
 * of the GNU Lesser General Public License Version 2.1 or later
 * (LGPLv2.1+), in which case the provisions of the LGPLv2.1+ are
 * applicable instead of those above.
 */

#include <librevenge/librevenge.h>

#include <map>
#include <memory>
#include <string>
#include <utility>

#include <cctype>
#include <cstring>
#include <system_error>
#include <charconv>
#include <cstdlib>
#include <locale.h>
#if defined(__APPLE__)
#include <xlocale.h>
#endif

// WireTuner: Boost.Spirit replaced by strtod_l in the C locale and std::from_chars; the grammar is the original's: a number,
// optional spaces, then an optional unit (pt, in, *, %, cm, mm), with spaces allowed around.
namespace
{

const char *skipSpaces(const char *first, const char *last)
{
	while (first != last && std::isspace((unsigned char)*first))
		++first;
	return first;
}

bool findDouble(const librevenge::RVNGString &str, double &res, librevenge::RVNGUnit &unit)
{
	if (str.empty())
		return false;

	const char *first = skipSpaces(str.cstr(), str.cstr() + str.size());
	const char *const last = str.cstr() + str.size();
	if (first != last && *first == '+')
		++first;
	static const locale_t cLocale = newlocale(LC_ALL_MASK, "C", nullptr);
	char *end = nullptr;
	const double value = strtod_l(first, &end, cLocale);
	if (!end || end == first)
		return false;
	first = skipSpaces(end, last);
	const size_t rest = size_t(last - first);
	double ratio = 1;
	using namespace librevenge;
	if (rest >= 2 && std::strncmp(first, "pt", 2) == 0)
	{
		unit = RVNG_POINT;
		first += 2;
	}
	else if (rest >= 2 && std::strncmp(first, "in", 2) == 0)
	{
		unit = RVNG_INCH;
		first += 2;
	}
	else if (rest >= 1 && *first == '*')
	{
		unit = RVNG_TWIP;
		first += 1;
	}
	else if (rest >= 1 && *first == '%')
	{
		unit = RVNG_PERCENT;
		ratio = 100.0;
		first += 1;
	}
	else if (rest >= 2 && std::strncmp(first, "cm", 2) == 0)
	{
		unit = RVNG_INCH;
		ratio = 2.54;
		first += 2;
	}
	else if (rest >= 2 && std::strncmp(first, "mm", 2) == 0)
	{
		unit = RVNG_INCH;
		ratio = 25.4;
		first += 2;
	}
	else
		unit = RVNG_GENERIC;
	if (skipSpaces(first, last) != last)
		return false;
	res = value / ratio;
	return true;
}

bool findInt(const librevenge::RVNGString &str, int &res)
{
	if (str.empty())
		return false;

	const char *first = skipSpaces(str.cstr(), str.cstr() + str.size());
	const char *const last = str.cstr() + str.size();
	if (first != last && *first == '+')
		++first;
	const std::from_chars_result parsed = std::from_chars(first, last, res);
	return parsed.ec == std::errc() && skipSpaces(parsed.ptr, last) == last;
}

bool findBool(const librevenge::RVNGString &str, bool &res)
{
	if (str.empty())
		return false;

	const char *first = skipSpaces(str.cstr(), str.cstr() + str.size());
	const char *const last = str.cstr() + str.size();
	std::string word;
	while (first != last && !std::isspace((unsigned char)*first))
		word += char(std::tolower((unsigned char)*first++));
	if (skipSpaces(first, last) != last)
		return false;
	if (word == "true")
		res = true;
	else if (word == "false")
		res = false;
	else
		return false;
	return true;
}

} // anonymous namespace

namespace librevenge
{

class RVNGPropertyListElement
{
public:
	RVNGPropertyListElement() : m_prop(nullptr), m_vec(nullptr) {}
	RVNGPropertyListElement(const RVNGPropertyListElement &elem)
		: m_prop(elem.m_prop ? elem.m_prop->clone() : nullptr),
		  m_vec(elem.m_vec ? static_cast<RVNGPropertyListVector *>(elem.m_vec->clone()) : nullptr) {}
	/*
	 * Caution, following constructor does not allocate memory but takes as
	 * arguments pre-allocated memory that this class takes ownership of.
	 * Deallocating this memory outside this class can result in double free.
	 */
	RVNGPropertyListElement(RVNGProperty *prop, RVNGPropertyListVector *vec)
		: m_prop(prop), m_vec(vec) {}
	~RVNGPropertyListElement()
	{
	}
	RVNGPropertyListElement &operator=(const RVNGPropertyListElement &elem)
	{
		m_prop.reset(elem.m_prop ? elem.m_prop->clone() : nullptr);
		m_vec.reset(elem.m_vec ? static_cast<RVNGPropertyListVector *>(elem.m_vec->clone()) : nullptr);
		return *this;
	}
	std::unique_ptr<RVNGProperty> m_prop;
	std::unique_ptr<RVNGPropertyListVector> m_vec;
};

class RVNGPropertyListImpl
{
public:
	RVNGPropertyListImpl() : m_map() {}
	RVNGPropertyListImpl(const RVNGPropertyListImpl &plist) : m_map(plist.m_map) {}
	~RVNGPropertyListImpl() {}
	RVNGPropertyListImpl &operator=(const RVNGPropertyListImpl &plist);
	void insert(const char *name, RVNGProperty *prop);
	void insert(const char *name, RVNGPropertyListVector *vec);
	const RVNGProperty *operator[](const char *name) const;
	const RVNGPropertyListVector *child(const char *name) const;
	void remove(const char *name);
	void clear();
	bool empty() const;

	mutable std::map<std::string, RVNGPropertyListElement> m_map;
};

RVNGPropertyListImpl &RVNGPropertyListImpl::operator=(const RVNGPropertyListImpl &plist)
{
	m_map = plist.m_map;
	return *this;
}

const RVNGProperty *RVNGPropertyListImpl::operator[](const char *name) const
{
	auto i = m_map.find(name);
	if (i != m_map.end())
		return i->second.m_prop.get();
	return nullptr;
}

const RVNGPropertyListVector *RVNGPropertyListImpl::child(const char *name) const
{
	auto i = m_map.find(name);
	if (i != m_map.end())
	{
		return i->second.m_vec.get();
	}

	return nullptr;
}

void RVNGPropertyListImpl::insert(const char *name, RVNGProperty *prop)
{
	auto i = m_map.lower_bound(name);
	if (i != m_map.end() && !(m_map.key_comp()(name, i->first)))
	{
		i->second.m_vec = nullptr;
		i->second.m_prop.reset(prop);
		return;
	}
	m_map.insert(i, std::map<std::string, RVNGPropertyListElement>::value_type(name, RVNGPropertyListElement(prop, nullptr)));
}

void RVNGPropertyListImpl::insert(const char *name, RVNGPropertyListVector *vec)
{
	auto i = m_map.lower_bound(name);
	if (i != m_map.end() && !(m_map.key_comp()(name, i->first)))
	{
		i->second.m_prop = nullptr;
		i->second.m_vec.reset(vec);
		return;
	}
	m_map.insert(i, std::map<std::string, RVNGPropertyListElement>::value_type(name, RVNGPropertyListElement(nullptr, vec)));
}

void RVNGPropertyListImpl::remove(const char *name)
{
	auto i = m_map.find(name);
	if (i != m_map.end())
	{
		m_map.erase(i);
	}
}

void RVNGPropertyListImpl::clear()
{
	m_map.clear();
}

bool RVNGPropertyListImpl::empty() const
{
	return m_map.empty();
}

RVNGPropertyList::RVNGPropertyList() :
	m_impl(new RVNGPropertyListImpl())
{
}

RVNGPropertyList::RVNGPropertyList(const RVNGPropertyList &propList) :
	m_impl(new RVNGPropertyListImpl(*(propList.m_impl)))
{
}

RVNGPropertyList::~RVNGPropertyList()
{
	delete m_impl;
}

void RVNGPropertyList::insert(const char *name, RVNGProperty *prop)
{
	m_impl->insert(name, prop);
}

void RVNGPropertyList::insert(const char *name, const int val)
{
	m_impl->insert(name, RVNGPropertyFactory::newIntProp(val));
}

void RVNGPropertyList::insert(const char *name, const bool val)
{
	m_impl->insert(name, RVNGPropertyFactory::newBoolProp(val));
}

void RVNGPropertyList::insert(const char *name, const char *val)
{
	insert(name, RVNGString(val));
}

void RVNGPropertyList::insert(const char *name, const RVNGString &val)
{
	int valInt = 0;
	if (findInt(val, valInt))
	{
		insert(name, valInt);
		return;
	}
	double valDouble = 0.0;
	RVNGUnit valUnit;
	if (findDouble(val, valDouble, valUnit))
	{
		insert(name, valDouble, valUnit);
		return;
	}
	bool valBool = false;
	if (findBool(val, valBool))
	{
		insert(name, valBool);
		return;
	}
	m_impl->insert(name, RVNGPropertyFactory::newStringProp(val));
}

void RVNGPropertyList::insert(const char *name, const unsigned char *buffer, const unsigned long bufferSize)
{
	m_impl->insert(name, RVNGPropertyFactory::newBinaryDataProp(buffer, bufferSize));
}

void RVNGPropertyList::insert(const char *name, const RVNGBinaryData &data)
{
	m_impl->insert(name, RVNGPropertyFactory::newBinaryDataProp(data));
}

void RVNGPropertyList::insert(const char *name, const double val, const RVNGUnit units)
{
	if (units == RVNG_INCH)
		m_impl->insert(name, RVNGPropertyFactory::newInchProp(val));
	else if (units == RVNG_PERCENT)
		m_impl->insert(name, RVNGPropertyFactory::newPercentProp(val));
	else if (units == RVNG_POINT)
		m_impl->insert(name, RVNGPropertyFactory::newPointProp(val));
	else if (units == RVNG_TWIP)
		m_impl->insert(name, RVNGPropertyFactory::newTwipProp(val));
	else if (units == RVNG_GENERIC)
		m_impl->insert(name, RVNGPropertyFactory::newDoubleProp(val));
}

void RVNGPropertyList::insert(const char *name, const RVNGPropertyListVector &vec)
{
	m_impl->insert(name, static_cast<RVNGPropertyListVector *>(vec.clone()));
}

void RVNGPropertyList::remove(const char *name)
{
	m_impl->remove(name);
}

const RVNGPropertyList &RVNGPropertyList::operator=(const RVNGPropertyList &propList)
{
	RVNGPropertyList tmp(propList);
	std::swap(m_impl, tmp.m_impl);
	return *this;
}

const RVNGProperty *RVNGPropertyList::operator[](const char *name) const
{
	return (*m_impl)[name];
}

const RVNGPropertyListVector *RVNGPropertyList::child(const char *name) const
{
	return m_impl->child(name);
}

void RVNGPropertyList::clear()
{
	m_impl->clear();
}

bool RVNGPropertyList::empty() const
{
	return m_impl->empty();
}


RVNGString RVNGPropertyList::getPropString() const
{
	RVNGString propString;
	RVNGPropertyList::Iter i(*this);
	if (!i.last())
	{
		propString.append(i.key());
		propString.append(": ");
		if (i.child())
			propString.append(i.child()->getPropString().cstr());
		else
			propString.append(i()->getStr().cstr());
		for (; i.next();)
		{
			propString.append(", ");
			propString.append(i.key());
			propString.append(": ");
			if (i.child())
				propString.append(i.child()->getPropString().cstr());
			else
				propString.append(i()->getStr().cstr());
		}
	}
	return propString;
}

#if 0
void RVNGPropertyList::swap(RVNGPropertyList &other)
{
	std::swap(m_impl, other.m_impl);
}
#endif

class RVNGPropertyListIterImpl
{
public:
	RVNGPropertyListIterImpl(const RVNGPropertyListImpl *impl);
	void rewind();
	bool next();
	bool last();
	const RVNGProperty *operator()() const;
	const RVNGPropertyListVector *child() const;
	const char *key() const;

private:
	// not implemented
	RVNGPropertyListIterImpl(const RVNGPropertyListIterImpl &other);
	RVNGPropertyListIterImpl &operator=(const RVNGPropertyListIterImpl &other);

private:
	bool m_imaginaryFirst;
	std::map<std::string, RVNGPropertyListElement>::iterator m_iter;
	std::map<std::string, RVNGPropertyListElement> *m_map;
};


RVNGPropertyListIterImpl::RVNGPropertyListIterImpl(const RVNGPropertyListImpl *impl) :
	m_imaginaryFirst(false),
	m_iter(impl->m_map.begin()),
	m_map(&impl->m_map)
{
}

void RVNGPropertyListIterImpl::rewind()
{
	// rewind to an imaginary element that preceeds the first one
	m_imaginaryFirst = true;
	m_iter = m_map->begin();
}

bool RVNGPropertyListIterImpl::next()
{
	if (!m_imaginaryFirst)
		++m_iter;
	if (m_iter==m_map->end())
		return false;
	m_imaginaryFirst = false;

	return true;
}

bool RVNGPropertyListIterImpl::last()
{
	return m_iter == m_map->end();
}

const RVNGProperty *RVNGPropertyListIterImpl::operator()() const
{
	if (m_iter->second.m_prop)
		return m_iter->second.m_prop.get();
	if (m_iter->second.m_vec)
		return m_iter->second.m_vec.get();
	return nullptr;
}

const RVNGPropertyListVector *RVNGPropertyListIterImpl::child() const
{
	if (m_iter->second.m_vec)
		return m_iter->second.m_vec.get();
	return nullptr;
}

const char *RVNGPropertyListIterImpl::key() const
{
	return m_iter->first.c_str();
}

RVNGPropertyList::Iter::Iter(const RVNGPropertyList &propList) :
	m_iterImpl(new RVNGPropertyListIterImpl(propList.m_impl))
{
}

RVNGPropertyList::Iter::~Iter()
{
	delete m_iterImpl;
}

void RVNGPropertyList::Iter::rewind()
{
	// rewind to an imaginary element that preceeds the first one
	m_iterImpl->rewind();
}

bool RVNGPropertyList::Iter::next()
{
	return m_iterImpl->next();
}

bool RVNGPropertyList::Iter::last()
{
	return m_iterImpl->last();
}

const RVNGProperty *RVNGPropertyList::Iter::operator()() const
{
	return (*m_iterImpl)();
}

const RVNGPropertyListVector *RVNGPropertyList::Iter::child() const
{
	return m_iterImpl->child();
}

const char *RVNGPropertyList::Iter::key() const
{
	return m_iterImpl->key();
}

}

/* vim:set shiftwidth=4 softtabstop=4 noexpandtab: */
