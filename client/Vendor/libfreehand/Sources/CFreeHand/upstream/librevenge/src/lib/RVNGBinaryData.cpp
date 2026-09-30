/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: t; c-basic-offset: 4 -*- */
/* librevenge
 * Version: MPL 2.0 / LGPLv2.1+
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Major Contributor(s):
 * Copyright (C) 2007 Fridrich Strba (fridrich.strba@bluewin.ch)
 *
 * For minor contributions see the git repository.
 *
 * Alternatively, the contents of this file may be used under the terms
 * of the GNU Lesser General Public License Version 2.1 or later
 * (LGPLv2.1+), in which case the provisions of the LGPLv2.1+ are
 * applicable instead of those above.
 */

#include <librevenge/librevenge.h>


#include <algorithm>
#include <iterator>
#include <memory>
#include <vector>
#include <string>
#include <stdarg.h>
#include <stdio.h>

#include "RVNGMemoryStream.h"


namespace librevenge
{

namespace
{

struct DataImpl
{
	DataImpl() : m_buf(), m_stream() {}

	std::vector<unsigned char> m_buf;
	std::unique_ptr<RVNGMemoryInputStream> m_stream;
};

// WireTuner: Boost's archive iterators replaced by a plain base64 codec (same results: whitespace
// is skipped, decoding stops at the first '=', output is padded with '=').
const char base64Alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

int base64Value(char c)
{
	if (c >= 'A' && c <= 'Z') return c - 'A';
	if (c >= 'a' && c <= 'z') return c - 'a' + 26;
	if (c >= '0' && c <= '9') return c - '0' + 52;
	if (c == '+') return 62;
	if (c == '/') return 63;
	return -1;
}

void convertFromBase64(std::vector<unsigned char> &result, const std::string &source)
{
	unsigned accumulator = 0;
	int bits = 0;
	for (char c : source)
	{
		if (c == '=')
			break;
		const int value = base64Value(c);
		if (value < 0)
			continue;
		accumulator = (accumulator << 6) | unsigned(value);
		bits += 6;
		if (bits >= 8)
		{
			bits -= 8;
			result.push_back((unsigned char)((accumulator >> bits) & 0xff));
		}
	}
}

void convertToBase64(std::string &result, const std::vector<unsigned char> &source)
{
	std::string encoded;
	size_t i = 0;
	for (; i + 2 < source.size(); i += 3)
	{
		const unsigned triple = (unsigned(source[i]) << 16) | (unsigned(source[i + 1]) << 8) | unsigned(source[i + 2]);
		encoded += base64Alphabet[(triple >> 18) & 63];
		encoded += base64Alphabet[(triple >> 12) & 63];
		encoded += base64Alphabet[(triple >> 6) & 63];
		encoded += base64Alphabet[triple & 63];
	}
	if (i < source.size())
	{
		const unsigned first = source[i];
		const unsigned second = i + 1 < source.size() ? source[i + 1] : 0;
		const unsigned triple = (first << 16) | (second << 8);
		encoded += base64Alphabet[(triple >> 18) & 63];
		encoded += base64Alphabet[(triple >> 12) & 63];
		encoded += i + 1 < source.size() ? base64Alphabet[(triple >> 6) & 63] : '=';
		encoded += '=';
	}
	result.insert(0, encoded);
}

void trim(std::string &text)
{
	const char *space = " \t\n\r\f\v";
	const size_t first = text.find_first_not_of(space);
	if (first == std::string::npos)
	{
		text.clear();
		return;
	}
	text.erase(text.find_last_not_of(space) + 1);
	text.erase(0, first);
}

} // anonymous namespace

struct RVNGBinaryDataImpl
{
	RVNGBinaryDataImpl();

	void makeUnique();

	std::shared_ptr<DataImpl> m_ptr;
};

RVNGBinaryDataImpl::RVNGBinaryDataImpl()
	: m_ptr(new DataImpl())
{
}

void RVNGBinaryDataImpl::makeUnique()
{
	if (!(m_ptr.use_count() == 1))
	{
		std::shared_ptr<DataImpl> ptr(new DataImpl());
		ptr->m_buf = m_ptr->m_buf;
		m_ptr = ptr;
	}
}

RVNGBinaryData::~RVNGBinaryData()
{
	delete m_binaryDataImpl;
}

RVNGBinaryData::RVNGBinaryData() :
	m_binaryDataImpl(new RVNGBinaryDataImpl)
{
}

RVNGBinaryData::RVNGBinaryData(const RVNGBinaryData &data) :
	m_binaryDataImpl(new RVNGBinaryDataImpl)
{
	m_binaryDataImpl->m_ptr = data.m_binaryDataImpl->m_ptr;
}

RVNGBinaryData::RVNGBinaryData(const unsigned char *buffer, const unsigned long bufferSize) :
	m_binaryDataImpl(nullptr)
{
	std::unique_ptr<RVNGBinaryDataImpl> impl(new RVNGBinaryDataImpl());
	if (buffer)
		impl->m_ptr->m_buf.assign(buffer, buffer + bufferSize);
	m_binaryDataImpl = impl.release();
}

RVNGBinaryData::RVNGBinaryData(const RVNGString &base64) :
	m_binaryDataImpl(nullptr)
{
	std::unique_ptr<RVNGBinaryDataImpl> impl(new RVNGBinaryDataImpl());
	std::string base64String(base64.cstr(), base64.size());
	trim(base64String);
	convertFromBase64(impl->m_ptr->m_buf, base64String);
	m_binaryDataImpl = impl.release();
}

RVNGBinaryData::RVNGBinaryData(const char *base64) :
	m_binaryDataImpl(nullptr)
{
	std::unique_ptr<RVNGBinaryDataImpl> impl(new RVNGBinaryDataImpl());
	if (base64)
	{
		std::string base64String(base64);
		trim(base64String);
		convertFromBase64(impl->m_ptr->m_buf, base64String);
	}
	m_binaryDataImpl = impl.release();
}

void RVNGBinaryData::append(const RVNGBinaryData &data)
{
	m_binaryDataImpl->makeUnique();

	m_binaryDataImpl->m_ptr->m_buf.insert(
		m_binaryDataImpl->m_ptr->m_buf.end(),
		data.m_binaryDataImpl->m_ptr->m_buf.begin(),
		data.m_binaryDataImpl->m_ptr->m_buf.end());
}

void RVNGBinaryData::appendBase64Data(const RVNGString &base64)
{
	std::string base64String(base64.cstr(), base64.size());
	trim(base64String);
	std::vector<unsigned char> buffer;
	convertFromBase64(buffer, base64String);
	if (!buffer.empty())
		append(buffer.data(), buffer.size());
}

void RVNGBinaryData::appendBase64Data(const char *base64)
{
	if (base64)
	{
		std::string base64String(base64);
		trim(base64String);
		std::vector<unsigned char> buffer;
		convertFromBase64(buffer, base64String);
		if (!buffer.empty())
			append(buffer.data(), buffer.size());
	}
}

void RVNGBinaryData::append(const unsigned char *buffer, const unsigned long bufferSize)
{
	if (buffer && bufferSize > 0)
	{
		m_binaryDataImpl->makeUnique();

		std::vector<unsigned char> &buf = m_binaryDataImpl->m_ptr->m_buf;
		buf.reserve(buf.size() + bufferSize);
		buf.insert(buf.end(), buffer, buffer + bufferSize);
	}
}

void RVNGBinaryData::append(const unsigned char c)
{
	m_binaryDataImpl->makeUnique();

	m_binaryDataImpl->m_ptr->m_buf.push_back(c);
}

void RVNGBinaryData::clear()
{
	m_binaryDataImpl->makeUnique();

	// clear and return allocated memory
	std::vector<unsigned char>().swap(m_binaryDataImpl->m_ptr->m_buf);
}

unsigned long RVNGBinaryData::size() const
{
	return (unsigned long)m_binaryDataImpl->m_ptr->m_buf.size();
}
bool RVNGBinaryData::empty() const
{
	return (unsigned long)m_binaryDataImpl->m_ptr->m_buf.empty();
}

RVNGBinaryData &RVNGBinaryData::operator=(const RVNGBinaryData &dataBuf)
{
	m_binaryDataImpl->m_ptr = dataBuf.m_binaryDataImpl->m_ptr;
	return *this;
}

const unsigned char *RVNGBinaryData::getDataBuffer() const
{
	if (m_binaryDataImpl->m_ptr->m_buf.empty())
		return nullptr;
	return m_binaryDataImpl->m_ptr->m_buf.data();
}

const RVNGString RVNGBinaryData::getBase64Data() const
{
	std::string base64;
	base64.reserve(m_binaryDataImpl->m_ptr->m_buf.size() / 4 * 3);
	convertToBase64(base64, m_binaryDataImpl->m_ptr->m_buf);
	return RVNGString(std::move(base64));
}

RVNGInputStream *RVNGBinaryData::getDataStream() const
{
	std::shared_ptr<DataImpl> data = m_binaryDataImpl->m_ptr;
	if (data->m_stream)
	{
		data->m_stream.reset();
	}
	if (data->m_buf.empty())
		return nullptr;
	data->m_stream.reset(new RVNGMemoryInputStream(data->m_buf.data(), data->m_buf.size()));
	return data->m_stream.get();
}

}

/* vim:set shiftwidth=4 softtabstop=4 noexpandtab: */
