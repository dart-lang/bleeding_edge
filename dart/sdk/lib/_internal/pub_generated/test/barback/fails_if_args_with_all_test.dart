import 'package:scheduled_test/scheduled_test.dart';
import '../../lib/src/exit_codes.dart' as exit_codes;
import '../descriptor.dart' as d;
import '../test_pub.dart';
import 'utils.dart';
main() {
  initConfig();
  setUp(() {
    d.appDir().create();
  });
  pubBuildAndServeShouldFail(
      "if a directory is passed with --all",
      args: ["example", "--all"],
      error: 'Directory names are not allowed if "--all" is passed.',
      exitCode: exit_codes.USAGE);
}
