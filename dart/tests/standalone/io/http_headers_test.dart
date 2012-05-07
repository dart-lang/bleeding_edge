// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#source("../../../runtime/bin/input_stream.dart");
#source("../../../runtime/bin/output_stream.dart");
#source("../../../runtime/bin/chunked_stream.dart");
#source("../../../runtime/bin/string_stream.dart");
#source("../../../runtime/bin/stream_util.dart");
#source("../../../runtime/bin/http.dart");
#source("../../../runtime/bin/http_impl.dart");
#source("../../../runtime/bin/http_parser.dart");
#source("../../../runtime/bin/http_utils.dart");

void testMultiValue() {
  _HttpHeaders headers = new _HttpHeaders();
  Expect.isNull(headers[HttpHeaders.PRAGMA]);
  headers.add(HttpHeaders.PRAGMA, "pragma1");
  Expect.equals(1, headers[HttpHeaders.PRAGMA].length);
  Expect.equals(1, headers["pragma"].length);
  Expect.equals(1, headers["Pragma"].length);
  Expect.equals(1, headers["PRAGMA"].length);
  Expect.equals("pragma1", headers.value(HttpHeaders.PRAGMA));

  headers.add(HttpHeaders.PRAGMA, "pragma2");
  Expect.equals(2, headers[HttpHeaders.PRAGMA].length);
  Expect.throws(() => headers.value(HttpHeaders.PRAGMA),
                (e) => e is HttpException);

  headers.add(HttpHeaders.PRAGMA, ["pragma3", "pragma4"]);
  Expect.listEquals(["pragma1", "pragma2", "pragma3", "pragma4"],
                    headers[HttpHeaders.PRAGMA]);

  headers.remove(HttpHeaders.PRAGMA, "pragma3");
  Expect.equals(3, headers[HttpHeaders.PRAGMA].length);
  Expect.listEquals(["pragma1", "pragma2", "pragma4"],
                    headers[HttpHeaders.PRAGMA]);

  headers.remove(HttpHeaders.PRAGMA, "pragma3");
  Expect.equals(3, headers[HttpHeaders.PRAGMA].length);

  headers.set(HttpHeaders.PRAGMA, "pragma5");
  Expect.equals(1, headers[HttpHeaders.PRAGMA].length);

  headers.set(HttpHeaders.PRAGMA, ["pragma6", "pragma7"]);
  Expect.equals(2, headers[HttpHeaders.PRAGMA].length);

  headers.removeAll(HttpHeaders.PRAGMA);
  Expect.isNull(headers[HttpHeaders.PRAGMA]);
}

void testDate() {
  Date date1 = new Date.withTimeZone(
      1999, Date.JUN, 11, 18, 46, 53, 0, new TimeZone.utc());
  String httpDate1 = "Fri, 11 Jun 1999 18:46:53 GMT";
  Date date2 = new Date.withTimeZone(
      2000, Date.AUG, 16, 12, 34, 56, 0, new TimeZone.utc());
  String httpDate2 = "Wed, 16 Aug 2000 12:34:56 GMT";

  _HttpHeaders headers = new _HttpHeaders();
  Expect.isNull(headers.date);
  headers.date = date1;
  Expect.equals(date1, headers.date);
  Expect.equals(httpDate1, headers.value(HttpHeaders.DATE));
  Expect.equals(1, headers[HttpHeaders.DATE].length);
  headers.add(HttpHeaders.DATE, httpDate2);
  Expect.equals(1, headers[HttpHeaders.DATE].length);
  Expect.equals(date2, headers.date);
  Expect.equals(httpDate2, headers.value(HttpHeaders.DATE));
  headers.set(HttpHeaders.DATE, httpDate1);
  Expect.equals(1, headers[HttpHeaders.DATE].length);
  Expect.equals(date1, headers.date);
  Expect.equals(httpDate1, headers.value(HttpHeaders.DATE));

  headers.set(HttpHeaders.DATE, "xxx");
  Expect.equals("xxx", headers.value(HttpHeaders.DATE));
  Expect.equals(null, headers.date);
}

void testExpires() {
  Date date1 = new Date.withTimeZone(
      1999, Date.JUN, 11, 18, 46, 53, 0, new TimeZone.utc());
  String httpDate1 = "Fri, 11 Jun 1999 18:46:53 GMT";
  Date date2 = new Date.withTimeZone(
      2000, Date.AUG, 16, 12, 34, 56, 0, new TimeZone.utc());
  String httpDate2 = "Wed, 16 Aug 2000 12:34:56 GMT";

  _HttpHeaders headers = new _HttpHeaders();
  Expect.isNull(headers.expires);
  headers.expires = date1;
  Expect.equals(date1, headers.expires);
  Expect.equals(httpDate1, headers.value(HttpHeaders.EXPIRES));
  Expect.equals(1, headers[HttpHeaders.EXPIRES].length);
  headers.add(HttpHeaders.EXPIRES, httpDate2);
  Expect.equals(1, headers[HttpHeaders.EXPIRES].length);
  Expect.equals(date2, headers.expires);
  Expect.equals(httpDate2, headers.value(HttpHeaders.EXPIRES));
  headers.set(HttpHeaders.EXPIRES, httpDate1);
  Expect.equals(1, headers[HttpHeaders.EXPIRES].length);
  Expect.equals(date1, headers.expires);
  Expect.equals(httpDate1, headers.value(HttpHeaders.EXPIRES));

  headers.set(HttpHeaders.EXPIRES, "xxx");
  Expect.equals("xxx", headers.value(HttpHeaders.EXPIRES));
  Expect.equals(null, headers.expires);
}

void testHost() {
  String host = "www.google.com";
  _HttpHeaders headers = new _HttpHeaders();
  Expect.isNull(headers.host);
  Expect.isNull(headers.port);
  headers.host = host;
  Expect.equals(host, headers.value(HttpHeaders.HOST));
  headers.port = 1234;
  Expect.equals("$host:1234", headers.value(HttpHeaders.HOST));
  headers.port = HttpClient.DEFAULT_HTTP_PORT;
  Expect.equals(host, headers.value(HttpHeaders.HOST));

  headers = new _HttpHeaders();
  headers.add(HttpHeaders.HOST, host);
  Expect.equals(host, headers.host);
  Expect.equals(HttpClient.DEFAULT_HTTP_PORT, headers.port);
  headers.add(HttpHeaders.HOST, "$host:4567");
  Expect.equals(1, headers[HttpHeaders.HOST].length);
  Expect.equals(host, headers.host);
  Expect.equals(4567, headers.port);

  headers = new _HttpHeaders();
  headers.add(HttpHeaders.HOST, "$host:xxx");
  Expect.equals("$host:xxx", headers.value(HttpHeaders.HOST));
  Expect.equals(host, headers.host);
  Expect.isNull(headers.port);

  headers = new _HttpHeaders();
  headers.add(HttpHeaders.HOST, ":1234");
  Expect.equals(":1234", headers.value(HttpHeaders.HOST));
  Expect.isNull(headers.host);
  Expect.equals(1234, headers.port);
}

void testEnumeration() {
  _HttpHeaders headers = new _HttpHeaders();
  Expect.isNull(headers[HttpHeaders.PRAGMA]);
  headers.add("My-Header-1", "value 1");
  headers.add("My-Header-2", "value 2");
  headers.add("My-Header-1", "value 3");
  bool myHeader1 = false;
  bool myHeader2 = false;
  int totalValues = 0;
  headers.forEach(f(String name, List<String> values) {
    totalValues += values.length;
    if (name == "my-header-1") {
      myHeader1 = true;
      Expect.isTrue(values.indexOf("value 1") != -1);
      Expect.isTrue(values.indexOf("value 3") != -1);
    }
    if (name == "my-header-2") {
      myHeader2 = true;
      Expect.isTrue(values.indexOf("value 2") != -1);
    }
  });
  Expect.isTrue(myHeader1);
  Expect.isTrue(myHeader2);
  Expect.equals(3, totalValues);
}

main() {
  testMultiValue();
  testExpires();
  testHost();
  testEnumeration();
}
