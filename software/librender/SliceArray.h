// 
// Copyright 2011-2015 Jeff Bush
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
//     http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// 


#pragma once

#include "SliceAllocator.h"

namespace librender
{
	
//
// Variable sized array that uses SliceAllocator. This uses a fast, 
// lock-free append. BUCKET_SIZE should be large enough to avoid 
// requiring too many allocations, but small enough that it doesn't 
// waste memory.
//
// reset() must be called on this object before calling reset() on the 
// SliceAllocator this object is using to properly clean up objects and
// to avoid stale pointers.
//
	
template <typename T, int BUCKET_SIZE>
class SliceArray
{
private:
	struct Bucket;

public:
	SliceArray() {}
	SliceArray(const SliceArray&) = delete;
	SliceArray& operator=(const SliceArray&) = delete;
	
	void setAllocator(SliceAllocator *allocator)
	{
		fAllocator = allocator;
	}
	
	void sort()
	{
		if (!fFirstBucket)
			return;		// Empty

		// Insertion sort.  This is fairly efficient when the array
		// is already mostly sorted, which is usually the case.
		for (iterator i = begin().next(), e = end(); i != e; ++i)
		{
			iterator j = i;
			while (j != begin() && *j.prev() > *j)
			{
				// swap
				T temp = *j;
				*j = *j.prev();
				*j.prev() = temp;
				--j;
			}
		}
	}
	
	void append(const T &copyFrom)
	{
		int index;
		Bucket *bucket;
		
		while (true)
		{
			// When a new bucket is appended because the previous one is
			// full, the last thing it does is sets fNextBucketIndex back to
			// 0.  Read that *first* so we don't get a stale value for
			// fLastBucket.  These are both volatile, so the compiler will not
			// reorder them.
			index = fNextBucketIndex;
			bucket = fLastBucket;
			if (index == BUCKET_SIZE || bucket == nullptr)
			{
				allocateBucket();
				continue;
			}

			if (__sync_bool_compare_and_swap(&fNextBucketIndex, index, index + 1))
				break;
		}

		bucket->items[index] = copyFrom;
	}
	
	void reset()
	{
		// Manually invoke destructor on items.
		for (Bucket *bucket = fFirstBucket; bucket; bucket = bucket->next)
			bucket->~Bucket();

		fFirstBucket = nullptr;
		fLastBucket = nullptr;
		fNextBucketIndex = 0;
	}

	class iterator
	{
	public:
		bool operator!=(const iterator &iter)
		{
			return fBucket != iter.fBucket || fIndex != iter.fIndex;
		}

		bool operator==(const iterator &iter)
		{
			return fBucket == iter.fBucket && fIndex == iter.fIndex;
		}
		
		const iterator &operator++()
		{
			// subtle: don't advance to next bucket if it is
			// null, otherwise the iterator will not be equal to 
			// end() when it advances past the last item.
			if (++fIndex == BUCKET_SIZE && fBucket->next)
			{
				fBucket = fBucket->next;
				fIndex = 0;
			}

			return *this;
		}
		
		const iterator &operator--()
		{
			if (--fIndex < 0)
			{
				fBucket = fBucket->prev;
				fIndex = BUCKET_SIZE - 1;
			}
			
			return *this;
		}
		
		T& operator*() const
		{
			return fBucket->items[fIndex];
		}

		iterator next() const
		{
			iterator tmp = *this;
			++tmp;
			return tmp;
		}
		
		iterator prev() const
		{
			iterator tmp = *this;
			--tmp;
			return tmp;
		}

	private:
		friend class SliceArray;
		
		iterator(Bucket *bucket, int index)
			: 	fBucket(bucket),
				fIndex(index)
		{}

		Bucket *fBucket;
		int fIndex;	// Index in current bucket
	};

	iterator begin() const
	{
		return iterator(fFirstBucket, 0);
	}
	
	iterator end() const
	{
		return iterator(fLastBucket, fNextBucketIndex);
	}
	
private:
	struct Bucket
	{
		Bucket *next = nullptr;
		Bucket *prev = nullptr;
		T items[BUCKET_SIZE];
	};

	void allocateBucket()
	{
		// Lock
		do
		{
			// Busy wait without calling the sync version of compare and swap.
			// This avoids creating traffic on the L2 interface, because it
			// only reads the L1 cached copy of the variable. When another thread
			// writes to the lock, the coherence broadcast will update the L1
			// cache and knock this out of the loop.
			while (fLock)
				;
		}
		while (!__sync_bool_compare_and_swap(&fLock, 0, 1));
		
		// Check first that someone didn't beat us to allocating the
		// bucket.
		if (fNextBucketIndex == BUCKET_SIZE || fLastBucket == nullptr)
		{
			if (fLastBucket)
			{
				// Append to end of chain
				Bucket *newBucket = new (*fAllocator) Bucket;
				newBucket->prev = fLastBucket;
				fLastBucket->next = newBucket;
				fLastBucket = newBucket;
			}
			else
			{
				// Allocate initial bucket
				fFirstBucket = new (*fAllocator) Bucket;
				fLastBucket = fFirstBucket;
			}
		
			// We must update fNextBucketIndex after fLastBucket to avoid a race
			// condition with append.  Because they are volatile, the compiler won't 
			// reorder them.
			fNextBucketIndex = 0;
		}
		
		fLock = 0;
		__sync_synchronize();
	}

	static int compareElements(const void *t1, const void *t2)
	{
		return *reinterpret_cast<const T*>(t1) > *reinterpret_cast<const T*>(t2) ? 1 : -1;
	}

	Bucket *fFirstBucket = nullptr;
	Bucket * volatile fLastBucket = nullptr;
	volatile int fNextBucketIndex = 0; // When the bucket is full, this will equal BUCKET_SIZE
	SliceAllocator *fAllocator = nullptr;
	volatile int fLock = 0;
};

}
