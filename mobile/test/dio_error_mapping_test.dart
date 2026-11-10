import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_virtual_outfit/core/network/api_error.dart';
import 'package:ai_virtual_outfit/core/network/dio_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DioClient error mapping & ApiException tests', () {
    final requestOptions = RequestOptions(path: '/api/v1/try-ons');

    test('maps FastAPI 400 MISSING_INPUT_IMAGE JSON error accurately', () {
      final dioError = DioException(
        requestOptions: requestOptions,
        type: DioExceptionType.badResponse,
        response: Response<dynamic>(
          requestOptions: requestOptions,
          statusCode: 400,
          data: {
            'error_code': 'MISSING_INPUT_IMAGE',
            'message': 'Both person_image and garment_image are required.',
            'details': {'missing_field': 'garment_image'},
          },
        ),
      );

      final apiError = DioClient.mapDioException(dioError);
      expect(apiError.errorCode, ApiErrorCode.missingInputImage);
      expect(apiError.rawCode, 'MISSING_INPUT_IMAGE');
      expect(apiError.statusCode, 400);
      expect(apiError.isNetworkError, isFalse);
      expect(apiError.details?['missing_field'], 'garment_image');
    });

    test('maps 413 FILE_TOO_LARGE and 415 UNSUPPORTED_MEDIA_TYPE', () {
      final error413 = DioClient.mapDioException(
        DioException(
          requestOptions: requestOptions,
          type: DioExceptionType.badResponse,
          response: Response<dynamic>(
            requestOptions: requestOptions,
            statusCode: 413,
            data: jsonEncode({
              'error_code': 'FILE_TOO_LARGE',
              'message': 'Uploaded image exceeds 10 MB limit.',
            }),
          ),
        ),
      );
      expect(error413.errorCode, ApiErrorCode.fileTooLarge);
      expect(error413.statusCode, 413);
      expect(error413.isNetworkError, isFalse);
    });

    test('maps binary Uint8List JSON payload when /image returns 409 RESULT_NOT_READY', () {
      final jsonBytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'error_code': 'RESULT_NOT_READY',
            'message': 'Result image is not available yet.',
          }),
        ),
      );

      final dioError = DioException(
        requestOptions: RequestOptions(path: '/api/v1/try-ons/123/image'),
        type: DioExceptionType.badResponse,
        response: Response<List<int>>(
          requestOptions: RequestOptions(path: '/api/v1/try-ons/123/image'),
          statusCode: 409,
          data: jsonBytes,
        ),
      );

      final apiError = DioClient.mapDioException(dioError);
      expect(apiError.errorCode, ApiErrorCode.resultNotReady);
      expect(apiError.statusCode, 409);
      expect(apiError.isNetworkError, isFalse);
    });

    test('distinguishes connectionError and timeouts with isNetworkError = true', () {
      final connectionDioError = DioException(
        requestOptions: requestOptions,
        type: DioExceptionType.connectionError,
        message: 'SocketException: Connection refused',
      );
      final mappedConnError = DioClient.mapDioException(connectionDioError);
      expect(mappedConnError.errorCode, ApiErrorCode.networkError);
      expect(mappedConnError.isNetworkError, isTrue);

      final timeoutDioError = DioException(
        requestOptions: requestOptions,
        type: DioExceptionType.receiveTimeout,
        message: 'Receive timeout',
      );
      final mappedTimeoutError = DioClient.mapDioException(timeoutDioError);
      expect(mappedTimeoutError.errorCode, ApiErrorCode.timeoutError);
      expect(mappedTimeoutError.isNetworkError, isTrue);
    });
  });
}

