/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

import 'package:media_kit/media_kit.dart';

import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';

/// {@template ohos_video_controller}
///
/// OhosVideoController
/// ----------------------
///
/// The [PlatformVideoController] implementation based on native C/C++ used on Ohos.
///
/// {@endtemplate}
class OhosVideoController extends PlatformVideoController {
  /// Whether [OhosVideoController] is supported on the current platform or not.
  static bool get supported => Platform.operatingSystem == 'ohos';

  /// Pointer address to the global object reference of `OHNativeWindow`.
  final ValueNotifier<int?> wid = ValueNotifier<int?>(null);

  /// [Lock] used to synchronize [onLoadHooks], [onUnloadHooks] & [subscription].
  final lock = Lock();

  NativePlayer get platform => player.platform as NativePlayer;

  Future<void> setProperty(String key, String value) async {
    await platform.setProperty(key, value, waitForInitialization: false);
  }

  Future<void> setProperties(Map<String, String> properties) async {
    for (final entry in properties.entries) {
      await setProperty(entry.key, entry.value);
    }
  }

  /// [StreamSubscription] for listening to video [Rect].
  StreamSubscription<VideoParams>? videoParamsSubscription;

  /// Whether the video is rendered into a native XComponent instead of a
  /// Flutter texture. Required for HDR output, see
  /// [VideoControllerConfiguration.usePlatformView].
  bool get usePlatformView => configuration.usePlatformView;

  /// Identifier of the platform view currently backing this controller.
  int? _platformViewId;

  /// {@macro ohos_video_controller}
  OhosVideoController._(
    super.player,
    super.configuration,
  ) {
    videoParamsSubscription = player.stream.videoParams.listen(
      (event) => lock.synchronized(() async {
        final int width;
        final int height;
        if (event.rotate == 0 || event.rotate == 180) {
          width = event.dw ?? 0;
          height = event.dh ?? 0;
        } else {
          // width & height are swapped for 90 or 270 degrees rotation.
          width = event.dh ?? 0;
          height = event.dw ?? 0;
        }

        final isZero = width == 0 || height == 0;
        final isSame = width == rect.value?.width.toInt() &&
            height == rect.value?.height.toInt();
        if (isZero || isSame) {
          return;
        }

        // A platform view has no Flutter texture to resize: the XComponent
        // owns the surface. Its render size still has to be pinned, though.
        // Under Flutter 3.44's hybrid composition the XComponent is laid out
        // at the video's unscaled size times the device pixel ratio (e.g.
        // 13440x7560 for a 4K stream) and scaled down by the compositor, so
        // the window geometry mpv would otherwise read back is far past the
        // per-axis surface limit and comes back clamped out of shape — a
        // vertically squashed picture. Pinned, mpv sets the buffer geometry to
        // this size itself and the compositor scales it into the view.
        if (!usePlatformView) {
          final handle = await player.handle;

          await _channel.invokeMethod(
            'VideoOutputManager.SetSurfaceSize',
            {
              'handle': handle.toString(),
              'width': width.toString(),
              'height': height.toString(),
            },
          );
        }
        await setProperties({
          'ohos-surface-size': [width, height].join('x'),
        });

        rect.value = Rect.fromLTWH(
          0.0,
          0.0,
          width.toDouble(),
          height.toDouble(),
        );

        if (!waitUntilFirstFrameRenderedCompleter.isCompleted) {
          waitUntilFirstFrameRenderedCompleter.complete();
        }
      }),
    );
  }

  /// {@macro ohos_video_controller}
  static Future<PlatformVideoController> create(
    Player player,
    VideoControllerConfiguration configuration,
  ) async {
    final bool isEmulator = await _channel.invokeMethod('Utils.IsEmulator');
    if (isEmulator) {
      throw UnsupportedError(
        '[VideoController] does not support emulator.'
        ' '
        'Please use actual device.',
      );
    }

    Future<String> getDefaultHwdec() async {
      bool hw = configuration.enableHardwareAcceleration;
      return hw ? 'auto' : 'no';
    }

    // Update [configuration] to have default values.
    configuration = configuration.copyWith(
      vo: configuration.vo ?? 'gpu-next',
      hwdec: configuration.hwdec ?? await getDefaultHwdec(),
    );

    // Retrieve the native handle of the [Player].
    final handle = await player.handle;
    // Return the existing [VideoController] if it's already created.
    if (_controllers.containsKey(handle)) {
      return _controllers[handle]!;
    }

    // Creation:
    final controller = OhosVideoController._(
      player,
      configuration,
    );

    // Register [_dispose] for execution upon [Player.dispose].
    player.platform?.release.add(controller._dispose);

    // Store the [VideoController] in the [_controllers].
    _controllers[handle] = controller;

    // Properties that do not depend on how the surface is obtained.
    final common = <String, String>{
      'hwdec': configuration.hwdec!,
      'vid': 'auto',
      'force-window': 'yes',
      'sub-use-margins': 'no',
      'sub-scale-with-window': 'no',
      'osd-font': 'HarmonyOS Sans SC',
      'vd-lavc-ohos-smart-fluency': 'yes',
      if (configuration.ohosHdrMode != null)
        'ohos-hdr-mode': configuration.ohosHdrMode!,
      if (configuration.ohosHdrTargetPeak != null)
        'target-peak': configuration.ohosHdrTargetPeak!.toStringAsFixed(0),
    };

    if (configuration.usePlatformView) {
      // The surface belongs to an XComponent that Flutter has not built yet.
      // Everything except the output is configured now; `wid` and `vo` are
      // set once the widget reports the platform view through
      // [attachPlatformView].
      await controller.lock.synchronized(() async {
        await controller.setProperty('vo', 'null');
        await controller.setProperties(common);
      });
      return controller;
    }

    final Map<dynamic, dynamic>? data = await _channel.invokeMethod(
      'VideoOutputManager.Create',
      {
        'handle': handle.toString(),
      },
    );

    if (data == null) {
      throw StateError('[OhosVideoController] failed to create video output.');
    }

    final id = (data['id'] as num).toInt();
    final wid = (data['wid'] as num).toInt();
    final rect = Rect.fromLTWH(
      (data['rect']['left'] as num).toDouble(),
      (data['rect']['top'] as num).toDouble(),
      (data['rect']['width'] as num).toDouble(),
      (data['rect']['height'] as num).toDouble(),
    );

    controller.id.value = id;
    controller.rect.value = rect;
    controller.wid.value = wid;

    await controller.lock.synchronized(() async {
      // MPV's HarmonyOS video output requires a valid surface ID before the
      // GPU video output is initialized.
      await controller.setProperty('vo', 'null');
      await controller.setProperties(
        {
          'ohos-surface-size': '${rect.width.toInt()}x${rect.height.toInt()}',
          'wid': wid.toString(),
          ...common,
        },
      );
      await controller.setProperty('vo', configuration.vo!);
    });

    // Return the [PlatformVideoController].
    return controller;
  }

  /// Points the video output at the XComponent backing the platform view with
  /// the given [viewId].
  ///
  /// ArkUI creates the surface asynchronously, so the native side only replies
  /// once the XComponent actually has one. Called by the [Video] widget after
  /// it has created the platform view.
  Future<void> attachPlatformView(int viewId) async {
    if (!usePlatformView || _platformViewId == viewId) {
      return;
    }

    final surfaceId = await _channel.invokeMethod(
      'PlatformView.GetSurfaceId',
      {
        'viewId': viewId.toString(),
      },
    );
    if (surfaceId == null) {
      return;
    }

    _platformViewId = viewId;
    final surface = int.parse(surfaceId.toString());

    await lock.synchronized(() async {
      // As with the texture path, the surface has to be known before the GPU
      // video output is brought up.
      await setProperty('vo', 'null');
      await setProperty('wid', surface.toString());
      await setProperty('vo', configuration.vo!);
    });

    wid.value = surface;
  }

  /// Detaches and releases the platform view backing this controller.
  Future<void> detachPlatformView() async {
    final viewId = _platformViewId;
    if (viewId == null) {
      return;
    }
    _platformViewId = null;
    wid.value = null;

    await lock.synchronized(() async {
      await setProperty('vo', 'null');
    });
    await _channel.invokeMethod(
      'PlatformView.Dispose',
      {
        'viewId': viewId.toString(),
      },
    );
  }

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  @override
  Future<void> setSize({
    int? width,
    int? height,
  }) {
    throw UnsupportedError(
      '[OhosVideoController.setSize] is not available on Ohos',
    );
  }

  /// Disposes the instance. Releases allocated resources back to the system.
  Future<void> _dispose() async {
    await videoParamsSubscription?.cancel();
    await detachPlatformView();
    final handle = await player.handle;
    _controllers.remove(handle);
    await _channel.invokeMethod(
      'VideoOutputManager.Dispose',
      {
        'handle': handle.toString(),
      },
    );
    wid.dispose();
    super.dispose();
  }

  /// Currently created [OhosVideoController]s.
  static final _controllers = HashMap<int, OhosVideoController>();

  /// [MethodChannel] for invoking platform specific native implementation.
  static const _channel = MethodChannel('com.alexmercerind/media_kit_video');
}
