import 'package:scheduled_test/scheduled_test.dart';
import 'package:scheduled_test/scheduled_server.dart';
import 'package:shelf/shelf.dart' as shelf;
import '../descriptor.dart' as d;
import '../test_pub.dart';
main() {
  initConfig();
  setUp(d.validPackage.create);
  integration('upload form provides invalid JSON', () {
    var server = new ScheduledServer();
    d.credentialsFile(server, 'access token').create();
    var pub = startPublish(server);
    confirmPublish(pub);
    server.handle(
        'GET',
        '/api/packages/versions/new',
        (request) => new shelf.Response.ok('{not json'));
    pub.stderr.expect(emitsLines('Invalid server response:\n' '{not json'));
    pub.shouldExit(1);
  });
}
