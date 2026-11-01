import 'package:bao_remote/protocol.dart' show RpcError;
import 'package:bao_remote/review.dart' show ReviewUnavailable;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'resource errors keep their retry flag over RPC; corruption does not',
    () {
      for (final retryable in [false, true]) {
        final error = ReviewUnavailable(
          'checkpoint failed',
          retryable: retryable,
        );
        final decoded = RpcError.fromJson(RpcError.from(error).toJson())
            .toException();
        expect(decoded, isA<ReviewUnavailable>());
        expect((decoded as ReviewUnavailable).retryable, retryable);
        expect(decoded.message, 'checkpoint failed');
      }
      final legacy =
          RpcError.fromJson({
                'code': -32000,
                'message': 'broken checkpoint',
                'data': {'type': 'reviewUnavailable'},
              }).toException()
              as ReviewUnavailable;
      expect(legacy.retryable, isFalse);
    },
  );
}
