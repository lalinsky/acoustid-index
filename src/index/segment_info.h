// Copyright (C) 2011  Lukas Lalinsky
// Distributed under the MIT license, see the LICENSE file for details.

#ifndef ACOUSTID_SEGMENT_INFO_H_
#define ACOUSTID_SEGMENT_INFO_H_

#include "common.h"

namespace Acoustid {

class SegmentInfo
{
public:
	SegmentInfo(int id = 0, size_t blockCount = 0, uint32_t lastKey = 0)
		: m_id(id), m_blockCount(blockCount), m_lastKey(lastKey)
	{
	}

	QString name() const
	{
		return QString("segment_%1").arg(m_id);
	}

	QString indexFileName() const
	{
		return name() + ".fii";
	}

	QString dataFileName() const
	{
		return name() + ".fid";
	}

	void setId(int id)
	{
		m_id = id;
	}

	int id() const
	{
		return m_id;
	}

	uint32_t lastKey() const
	{
		return m_lastKey;
	}

	void setLastKey(uint32_t lastKey)
	{
		m_lastKey = lastKey;
	}

	size_t blockCount() const
	{
		return m_blockCount;
	}

	void setBlockCount(size_t blockCount)
	{
		m_blockCount = blockCount;
	}

private:
	int m_id;
	size_t m_blockCount;
	uint32_t m_lastKey;
};

typedef QList<SegmentInfo> SegmentInfoList;

}

#endif
