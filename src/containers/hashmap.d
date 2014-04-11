/**
 * Hash Set
 * Copyright: © 2014 Economic Modeling Specialists, Intl.
 * Authors: Brian Schott
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */

module containers.hashmap;

template HashMap(K, V) if (is (K == string))
{
	import containers.hash;
	alias HashMap = HashMap!(K, V, hashString);
}

template HashMap(K, V) if (!is (K == string))
{
	import containers.hash;
	alias HashMap = HashMap!(K, V, builtinHash!K);
}

/**
 * Associative array / hash map.
 * Params:
 *     K = the key type
 *     V = the value type
 *     hashFunction = the hash function to use on the keys
 * $(B Do not store pointers to GC-allocated memory in this container.)
 */
struct HashMap(K, V, alias hashFunction)
{
	/**
	 * Default and postblit constructors are disabled.
	 */
	@disable this();

	/// ditto
	@disable this(this);

	/**
	 * Constructs an HashMap with an initial bucket count of bucketCount. bucketCount
	 * must be a power of two.
	 */
	this(size_t bucketCount)
	in
	{
		assert ((bucketCount & (bucketCount - 1)) == 0, "bucketCount must be a power of two");
	}
	body
	{
		import std.conv;
		import std.allocator;
		sListNodeAllocator = allocate!(SListNodeAllocator)(Mallocator.it);
		emplace(sListNodeAllocator);
		buckets = cast(Bucket[]) Mallocator.it.allocate( // Valgrind
			bucketCount * Bucket.sizeof);
		assert (buckets.length == bucketCount);
		foreach (ref bucket; buckets)
			emplace(&bucket, sListNodeAllocator);
	}

	~this()
	{
		import std.allocator;
		foreach (ref bucket; buckets)
			typeid(typeof(bucket)).destroy(&bucket);
		Mallocator.it.deallocate(buckets);
		typeid(typeof(*sListNodeAllocator)).destroy(sListNodeAllocator);
		deallocate(Mallocator.it, sListNodeAllocator);
	}

	/**
	 * Supports ($D aa[key]) syntax.
	 */
	V opIndex(K key) const
	{
		import std.algorithm : find;
		import std.exception : enforce;
		import std.conv : text;
		size_t hash = generateHash(key);
		size_t index = hashToIndex(hash);
		foreach (r; buckets[index].range)
		{
			if (r == key)
				return r.value;
		}
		throw new Exception("'" ~ text(key) ~ "' not found in HashMap");
	}

	/**
	 * Supports $(D aa[key] = value;) syntax.
	 */
	void opIndexAssign(V value, K key)
	{
		insert(key, value);
	}

	/**
	 * Supports $(D key in aa) syntax.
	 */
	bool opBinaryRight(string op)(K key) const nothrow if (op == "in")
	{
		import std.algorithm : canFind;
		size_t index = hashIndex(key);
		return buckets[index].range.canFind(key);
	}

	/**
	 * Removes the value associated with the given key
	 * Returns: true if a value was actually removed.
	 */
	bool remove(K key)
	{
		size_t index = hashIndex(key);
		bool removed = buckets[index].remove(key);
		if (removed)
			_length--;
		return removed;
	}

	/**
	 * Number of key/value pairs in this aa
	 */
	size_t length() const @property
	{
		return _length;
	}

	/**
	 * Returns: A GC-allocates an array and fills it with the keys contained in this map.
	 */
	K[] keys() const @property
	out(result)
	{
		assert (result.length == _length);
	}
	body
	{
		import std.array;
		auto app = appender!(K[])();
		foreach (ref const bucket; buckets)
		{
			foreach (item; bucket.range)
				app.put(item.key);
		}
		return app.data;
	}

	/**
	 * Returns: A GC-allocated array containing the values contained in this map.
	 */
	V[] values() const @property
	out(result)
	{
		assert (result.length == _length);
	}
	body
	{
		import std.array;
		auto app = appender!(V[])();
		foreach (ref const bucket; buckets)
		{
			foreach (item; bucket.range)
				app.put(item.value);
		}
		return app.data;
	}

	/**
	 * Support for $(D foreach(key, value; aa)) { ... }) syntax;
	 */
	int opApply(int delegate(ref K, ref V) del)
	{
		int result = 0;
		outer: foreach (ref bucket; buckets)
		{
			foreach (ref node; bucket.range)
			{
				result = del(node.key, node.value);
				if (result != 0)
					return result;
			}
		}
		return result;
	}

private:

	import std.allocator;
	import std.traits;
	import memory.allocators;
	import containers.slist;

	enum bool storeHash = !isBasicType!K;

	void insert(K key, V value)
	{
		import std.algorithm;
		size_t hash = generateHash(key);
		size_t index = hashToIndex(hash);
		foreach (ref item; buckets[index].range)
		{
			static if (storeHash)
			{
				if (item.hash == hash && item.key == key)
				{
					item.value = value;
					return;
				}
			}
			else
			{
				if (item.key == key)
				{
					item.value = value;
					return;
				}
			}
		}
		static if (storeHash)
			buckets[index].put(Node(hash, key, value));
		else
			buckets[index].put(Node(key, value));
		_length++;
		if (shouldRehash)
			rehash();
	}

	/**
	 * Returns: true if the load factor has been exceeded
	 */
	bool shouldRehash() const pure nothrow @safe
	{
		return cast(float) _length / cast(float) buckets.length > 0.75;
	}

	/**
	 * Rehash the map.
	 */
	void rehash() @trusted
	{
		import std.allocator;
		import std.conv;
		immutable size_t newLength = buckets.length << 1;
		immutable size_t newSize = newLength * Bucket.sizeof;
		Bucket[] oldBuckets = buckets;
		assert (oldBuckets.ptr == buckets.ptr);
		buckets = cast(Bucket[]) Mallocator.it.allocate(newSize);
		auto newAllocator = allocate!(SListNodeAllocator)(Mallocator.it);
		assert (buckets);
		assert (buckets.length == newLength);
		foreach (ref bucket; buckets)
			emplace(&bucket, newAllocator);
		foreach (ref bucket; oldBuckets)
		{
			foreach (node; bucket.range)
			{
				static if (storeHash)
				{
					size_t index = hashToIndex(node.hash);
					buckets[index].put(Node(node.hash, node.key, node.value));
				}
				else
				{
					size_t hash = generateHash(node.value);
					size_t index = hashToIndex(hash);
					buckets[index].put(Node(node.key, node.value));
				}
			}
			typeid(typeof(bucket)).destroy(&bucket);
		}
		typeid(typeof(*sListNodeAllocator)).destroy(sListNodeAllocator);
		deallocate(Mallocator.it, sListNodeAllocator);
		Mallocator.it.deallocate(cast(void[]) oldBuckets);
		sListNodeAllocator = newAllocator;
	}

	size_t hashToIndex(size_t hash) const pure nothrow @safe
	in
	{
		assert (buckets.length > 0);
	}
	out (result)
	{
		import std.string;
		assert (result < buckets.length, "%d, %d".format(result, buckets.length));
	}
	body
	{
		return hash & (buckets.length - 1);
	}

	/**
	 * Move the bits a bit to the right. This trick was taken from the JRE
	 */
	size_t generateHash(K key) const nothrow @safe
	{
		size_t h = hashFunction(key);
		h ^= (h >>> 20) ^ (h >>> 12);
		return h ^ (h >>> 7) ^ (h >>> 4);
	}

	size_t hashIndex(K key) const nothrow @safe
	out (result)
	{
		assert (result < buckets.length);
	}
	body
	{
		return hashToIndex(generateHash(key));
	}

	struct Node
	{
		bool opEquals(ref const K key) const
		{
			return key == this.key;
		}

		static if (storeHash)
			size_t hash;
		K key;
		V value;
	}

	alias SListNodeAllocator = NodeAllocator!(Node.sizeof, 1024);
	alias Bucket = SList!(Node, SListNodeAllocator*);
	SListNodeAllocator* sListNodeAllocator;
	Bucket[] buckets;
	size_t _length;
}

///
unittest
{
	import std.stdio;
	import std.uuid;
	auto hm = HashMap!(string, int)(16);
	assert (hm.length == 0);
	assert (!hm.remove("abc"));
	hm["answer"] = 42;
	assert (hm.length == 1);
	assert ("answer" in hm);
	hm.remove("answer");
	assert (hm.length == 0);
	hm["one"] = 1;
	hm["one"] = 1;
	assert (hm.length == 1);
	assert (hm["one"] == 1);
	foreach (i; 0 .. 1000)
	{
		hm[randomUUID().toString] = i;
	}
	assert (hm.length == 1001);
	assert (hm.keys().length == hm.length);
	assert (hm.values().length == hm.length);
	foreach (ref k, ref v; hm) {}

	auto hm2 = HashMap!(char, char)(4);
	hm2['a'] = 'a';
}