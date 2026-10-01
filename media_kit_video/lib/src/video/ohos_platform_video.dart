/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:media_kit_video/src/video_controller/ohos_video_controller/ohos_video_controller.dart';

/// Must match the view type registered by `MediaKitVideoPlugin` on the ArkTS
/// side.
const String kOhosVideoViewType = 'com.alexmercerind/media_kit_video/view';

void _report(Object exception, StackTrace stacktrace) {
  debugPrint(exception.toString());
  debugPrint(stacktrace.toString());
}

/// {@template ohos_platform_video}
///
/// OhosPlatformVideo
/// -----------------
///
/// Renders the video into a native XComponent hosted by a HarmonyOS platform
/// view, rather than into a Flutter texture.
///
/// This is what makes HDR work. A Flutter texture is resampled into the
/// Flutter surface before reaching the screen, and that step drops the color
/// space and HDR metadata libmpv attaches to its NativeWindow, so HarmonyOS
/// never switches the panel into HDR mode. A hybrid composition platform view
/// is composited by the render service directly, so the metadata survives.
///
/// The view is composed by the engine's Hybrid Composition (HCPP), which
/// requires `enable_ohos_hybrid_composition` in the app's `buildinfo.json5`:
///
/// * The engine places, sizes, clips and shows the view from the
///   [PlatformViewLayer] it finds in each frame, like Android's HCPP. A view
///   that is missing from the layer tree stays hidden at 0x0, and then the
///   XComponent never gets a surface for mpv to render into.
/// * The view sits above the Flutter surface, and Flutter content painted
///   over it goes to the engine's overlay layer. Nothing below the video has
///   to be transparent any more.
/// * Touches that land on the bare video reach the native view first; the
///   ArkTS side hands them back to Flutter so the player's gestures still work.
///
/// {@endtemplate}
class OhosPlatformVideo extends StatefulWidget {
  /// The controller whose video output should be bound to the platform view.
  final OhosVideoController controller;

  /// {@macro ohos_platform_video}
  const OhosPlatformVideo({
    super.key,
    required this.controller,
  });

  @override
  State<OhosPlatformVideo> createState() => _OhosPlatformVideoState();
}

class _OhosPlatformVideoState extends State<OhosPlatformVideo> {
  /// Set once the view exists on the native side. The surface is only
  /// inserted into the tree then, so the engine is never asked to compose a
  /// view it does not know about.
  ExpensiveOhosViewController? _viewController;

  @override
  void initState() {
    super.initState();
    _create();
  }

  @override
  void dispose() {
    final controller = _viewController;
    _viewController = null;
    if (controller != null) {
      _release(widget.controller, controller);
    }
    super.dispose();
  }

  /// Destroys the view only after mpv has let go of the XComponent's window.
  /// Detaching is asynchronous (the `vo` is nulled under the player's lock),
  /// and a view disposed before that finishes leaves mpv writing frames into a
  /// released NativeWindow.
  static Future<void> _release(
    OhosVideoController player,
    ExpensiveOhosViewController view,
  ) async {
    try {
      await player.detachPlatformView();
    } catch (exception, stacktrace) {
      _report(exception, stacktrace);
    } finally {
      await view.dispose();
    }
  }

  Future<void> _create() async {
    final player = widget.controller;
    final controller = PlatformViewsService.initExpensiveOhosView(
      id: platformViewsRegistry.getNextPlatformViewId(),
      viewType: kOhosVideoViewType,
      layoutDirection: TextDirection.ltr,
      creationParamsCodec: const StandardMessageCodec(),
    );

    try {
      // No size: the engine takes the geometry from the layer tree.
      await controller.create();
    } catch (exception, stacktrace) {
      _report(exception, stacktrace);
      return;
    }

    if (!mounted) {
      controller.dispose();
      return;
    }

    setState(() {
      _viewController = controller;
    });

    // The XComponent's surface only exists once the engine has laid the view
    // out, so this resolves after the first frame that composes it.
    try {
      await player.attachPlatformView(controller.viewId);
    } catch (exception, stacktrace) {
      _report(exception, stacktrace);
      return;
    }

    // Leaving fullscreen before the surface came up disposes this state while
    // the attach is still pending. dispose()'s detach was a no-op then, so
    // undo the attach here or mpv keeps a window whose view is gone.
    if (!mounted) {
      try {
        await player.detachPlatformView();
      } catch (exception, stacktrace) {
        _report(exception, stacktrace);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _viewController;
    if (controller == null) {
      return const SizedBox.expand();
    }
    return OhosViewSurface(
      controller: controller,
      // The player's own gesture layer handles input on the video.
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
    );
  }
}
