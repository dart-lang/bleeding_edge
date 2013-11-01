// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
// VMOptions=--optimization-counter-threshold=10

// Library tag to be able to run in html test framework.
library uint32x4_shuffle_test;

import "package:expect/expect.dart";
import 'dart:typed_data';

void testShuffle() {
  var m = new Uint32x4(1, 2, 3, 4);
  var c;
  c = m.shuffle(Uint32x4.WZYX);
  Expect.equals(4, c.x);
  Expect.equals(3, c.y);
  Expect.equals(2, c.z);
  Expect.equals(1, c.w);
}

void testShuffleNonConstant(mask) {
  var m = new Uint32x4(1, 2, 3, 4);
  var c;
  c = m.shuffle(mask);
  if (mask == 1) {
    Expect.equals(2, c.x);
    Expect.equals(1, c.y);
    Expect.equals(1, c.z);
    Expect.equals(1, c.w);
  } else {
    Expect.equals(Uint32x4.YYYY + 1, mask);
    Expect.equals(3, c.x);
    Expect.equals(2, c.y);
    Expect.equals(2, c.z);
    Expect.equals(2, c.w);
  }
}

void testShuffleMix() {
  var m = new Uint32x4(1, 2, 3, 4);
  var n = new Uint32x4(5, 6, 7, 8);
  var c = m.shuffleMix(n, Uint32x4.XYXY);
  Expect.equals(1, c.x);
  Expect.equals(2, c.y);
  Expect.equals(5, c.z);
  Expect.equals(6, c.w);
}

main() {
  var xxxx = Uint32x4.XXXX + 1;
  var yyyy = Uint32x4.YYYY + 1;
  for (int i = 0; i < 20; i++) {
    testShuffle();
    testShuffleNonConstant(xxxx);
    testShuffleNonConstant(yyyy);
    testShuffleMix();
  }
}