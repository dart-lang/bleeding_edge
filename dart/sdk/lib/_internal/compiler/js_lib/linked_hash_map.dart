// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Efficient JavaScript based implementation of a linked hash map used as a
// backing map for constant maps and the [LinkedHashMap] patch

part of _js_helper;

class JsLinkedHashMap<K, V> implements LinkedHashMap<K, V>, InternalMap {
  int _length = 0;

  // The hash map contents are divided into three parts: one part for
  // string keys, one for numeric keys, and one for the rest. String
  // and numeric keys map directly to their linked cells, but the rest
  // of the entries are stored in bucket lists of the form:
  //
  //    [cell-0, cell-1, ...]
  //
  // where all keys in the same bucket share the same hash code.
  var _strings;
  var _nums;
  var _rest;

  // The keys and values are stored in cells that are linked together
  // to form a double linked list.
  LinkedHashMapCell _first;
  LinkedHashMapCell _last;

  // We track the number of modifications done to the key set of the
  // hash map to be able to throw when the map is modified while being
  // iterated over.
  int _modifications = 0;

  JsLinkedHashMap();


  int get length => _length;
  bool get isEmpty => _length == 0;
  bool get isNotEmpty => !isEmpty;

  Iterable<K> get keys {
    return new LinkedHashMapKeyIterable<K>(this);
  }

  Iterable<V> get values {
    return new MappedIterable<K, V>(keys, (each) => this[each]);
  }

  bool containsKey(Object key) {
    if (_isStringKey(key)) {
      var strings = _strings;
      if (strings == null) return false;
      LinkedHashMapCell cell = _getTableEntry(strings, key);
      return cell != null;
    } else if (_isNumericKey(key)) {
      var nums = _nums;
      if (nums == null) return false;
      LinkedHashMapCell cell = _getTableEntry(nums, key);
      return cell != null;
    } else {
      return internalContainsKey(key);
    }
  }

  bool internalContainsKey(Object key) {
    var rest = _rest;
    if (rest == null) return false;
    var bucket = _getBucket(rest, key);
    return internalFindBucketIndex(bucket, key) >= 0;
  }

  bool containsValue(Object value) {
    return keys.any((each) => this[each] == value);
  }

  void addAll(Map<K, V> other) {
    other.forEach((K key, V value) {
      this[key] = value;
    });
  }

  V operator[](Object key) {
    if (_isStringKey(key)) {
      var strings = _strings;
      if (strings == null) return null;
      LinkedHashMapCell cell = _getTableEntry(strings, key);
      return (cell == null) ? null : cell.hashMapCellValue;
    } else if (_isNumericKey(key)) {
      var nums = _nums;
      if (nums == null) return null;
      LinkedHashMapCell cell = _getTableEntry(nums, key);
      return (cell == null) ? null : cell.hashMapCellValue;
    } else {
      return internalGet(key);
    }
  }

  V internalGet(Object key) {
    var rest = _rest;
    if (rest == null) return null;
    var bucket = _getBucket(rest, key);
    int index = internalFindBucketIndex(bucket, key);
    if (index < 0) return null;
    LinkedHashMapCell cell = JS('var', '#[#]', bucket, index);
    return cell.hashMapCellValue;
  }

  void operator[]=(K key, V value) {
    if (_isStringKey(key)) {
      var strings = _strings;
      if (strings == null) _strings = strings = _newHashTable();
      _addHashTableEntry(strings, key, value);
    } else if (_isNumericKey(key)) {
      var nums = _nums;
      if (nums == null) _nums = nums = _newHashTable();
      _addHashTableEntry(nums, key, value);
    } else {
      internalSet(key, value);
    }
  }

  void internalSet(K key, V value) {
    var rest = _rest;
    if (rest == null) _rest = rest = _newHashTable();
    var hash = internalComputeHashCode(key);
    var bucket = JS('var', '#[#]', rest, hash);
    if (bucket == null) {
      LinkedHashMapCell cell = _newLinkedCell(key, value);
      _setTableEntry(rest, hash, JS('var', '[#]', cell));
    } else {
      int index = internalFindBucketIndex(bucket, key);
      if (index >= 0) {
        LinkedHashMapCell cell = JS('var', '#[#]', bucket, index);
        cell.hashMapCellValue = value;
      } else {
        LinkedHashMapCell cell = _newLinkedCell(key, value);
        JS('void', '#.push(#)', bucket, cell);
      }
    }
  }

  V putIfAbsent(K key, V ifAbsent()) {
    if (containsKey(key)) return this[key];
    V value = ifAbsent();
    this[key] = value;
    return value;
  }

  V remove(Object key) {
    if (_isStringKey(key)) {
      return _removeHashTableEntry(_strings, key);
    } else if (_isNumericKey(key)) {
      return _removeHashTableEntry(_nums, key);
    } else {
      return internalRemove(key);
    }
  }

  V internalRemove(Object key) {
    var rest = _rest;
    if (rest == null) return null;
    var bucket = _getBucket(rest, key);
    int index = internalFindBucketIndex(bucket, key);
    if (index < 0) return null;
    // Use splice to remove the [cell] element at the index and
    // unlink the cell before returning its value.
    LinkedHashMapCell cell = JS('var', '#.splice(#, 1)[0]', bucket, index);
    _unlinkCell(cell);
    // TODO(kasperl): Consider getting rid of the bucket list when
    // the length reaches zero.
    return cell.hashMapCellValue;
  }

  void clear() {
    if (_length > 0) {
      _strings = _nums = _rest = _first = _last = null;
      _length = 0;
      _modified();
    }
  }

  void forEach(void action(K key, V value)) {
    LinkedHashMapCell cell = _first;
    int modifications = _modifications;
    while (cell != null) {
      action(cell.hashMapCellKey, cell.hashMapCellValue);
      if (modifications != _modifications) {
        throw new ConcurrentModificationError(this);
      }
      cell = cell._next;
    }
  }

  void _addHashTableEntry(var table, K key, V value) {
    LinkedHashMapCell cell = _getTableEntry(table, key);
    if (cell == null) {
      _setTableEntry(table, key, _newLinkedCell(key, value));
    } else {
      cell.hashMapCellValue = value;
    }
  }

  V _removeHashTableEntry(var table, Object key) {
    if (table == null) return null;
    LinkedHashMapCell cell = _getTableEntry(table, key);
    if (cell == null) return null;
    _unlinkCell(cell);
    _deleteTableEntry(table, key);
    return cell.hashMapCellValue;
  }

  void _modified() {
    // Value cycles after 2^30 modifications. If you keep hold of an
    // iterator for that long, you might miss a modification
    // detection, and iteration can go sour. Don't do that.
    _modifications = (_modifications + 1) & 0x3ffffff;
  }

  // Create a new cell and link it in as the last one in the list.
  LinkedHashMapCell _newLinkedCell(K key, V value) {
    LinkedHashMapCell cell = new LinkedHashMapCell(key, value);
    if (_first == null) {
      _first = _last = cell;
    } else {
      LinkedHashMapCell last = _last;
      cell._previous = last;
      _last = last._next = cell;
    }
    _length++;
    _modified();
    return cell;
  }

  // Unlink the given cell from the linked list of cells.
  void _unlinkCell(LinkedHashMapCell cell) {
    LinkedHashMapCell previous = cell._previous;
    LinkedHashMapCell next = cell._next;
    if (previous == null) {
      assert(cell == _first);
      _first = next;
    } else {
      previous._next = next;
    }
    if (next == null) {
      assert(cell == _last);
      _last = previous;
    } else {
      next._previous = previous;
    }
    _length--;
    _modified();
  }

  static bool _isStringKey(var key) {
    return key is String && key != '__proto__';
  }

  static bool _isNumericKey(var key) {
    // Only treat unsigned 30-bit integers as numeric keys. This way,
    // we avoid converting them to strings when we use them as keys in
    // the JavaScript hash table object.
    return key is num && JS('bool', '(# & 0x3ffffff) === #', key, key);
  }

  int internalComputeHashCode(var key) {
    // We force the hash codes to be unsigned 30-bit integers to avoid
    // issues with problematic keys like '__proto__'. Another option
    // would be to throw an exception if the hash code isn't a number.
    return JS('int', '# & 0x3ffffff', key.hashCode);
  }

  static _getTableEntry(var table, var key) {
    return JS('var', '#[#]', table, key);
  }

  static void _setTableEntry(var table, var key, var value) {
    assert(value != null);
    JS('void', '#[#] = #', table, key, value);
  }

  static void _deleteTableEntry(var table, var key) {
    JS('void', 'delete #[#]', table, key);
  }

  List _getBucket(var table, var key) {
    var hash = internalComputeHashCode(key);
    return JS('var', '#[#]', table, hash);
  }

  int internalFindBucketIndex(var bucket, var key) {
    if (bucket == null) return -1;
    int length = JS('int', '#.length', bucket);
    for (int i = 0; i < length; i++) {
      LinkedHashMapCell cell = JS('var', '#[#]', bucket, i);
      if (cell.hashMapCellKey == key) return i;
    }
    return -1;
  }

  static _newHashTable() {
    // Create a new JavaScript object to be used as a hash table. Use
    // Object.create to avoid the properties on Object.prototype
    // showing up as entries.
    var table = JS('var', 'Object.create(null)');
    // Attempt to force the hash table into 'dictionary' mode by
    // adding a property to it and deleting it again.
    var temporaryKey = '<non-identifier-key>';
    _setTableEntry(table, temporaryKey, table);
    _deleteTableEntry(table, temporaryKey);
    return table;
  }

  String toString() => Maps.mapToString(this);
}

class LinkedHashMapCell {
  final hashMapCellKey;
  var hashMapCellValue;

  LinkedHashMapCell _next;
  LinkedHashMapCell _previous;

  LinkedHashMapCell(this.hashMapCellKey, this.hashMapCellValue);
}

class LinkedHashMapKeyIterable<E> extends Iterable<E>
                                  implements EfficientLength {
  final _map;
  LinkedHashMapKeyIterable(this._map);

  int get length => _map._length;
  bool get isEmpty => _map._length == 0;

  Iterator<E> get iterator {
    return new LinkedHashMapKeyIterator<E>(_map, _map._modifications);
  }

  bool contains(Object element) {
    return _map.containsKey(element);
  }

  void forEach(void f(E element)) {
    LinkedHashMapCell cell = _map._first;
    int modifications = _map._modifications;
    while (cell != null) {
      f(cell.hashMapCellKey);
      if (modifications != _map._modifications) {
        throw new ConcurrentModificationError(_map);
      }
      cell = cell._next;
    }
  }
}

class LinkedHashMapKeyIterator<E> implements Iterator<E> {
  final _map;
  final int _modifications;
  LinkedHashMapCell _cell;
  E _current;

  LinkedHashMapKeyIterator(this._map, this._modifications) {
    _cell = _map._first;
  }

  E get current => _current;

  bool moveNext() {
    if (_modifications != _map._modifications) {
      throw new ConcurrentModificationError(_map);
    } else if (_cell == null) {
      _current = null;
      return false;
    } else {
      _current = _cell.hashMapCellKey;
      _cell = _cell._next;
      return true;
    }
  }
}
