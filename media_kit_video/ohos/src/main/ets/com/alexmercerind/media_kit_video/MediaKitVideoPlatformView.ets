/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright © 2025 & onwards, Bao Han <erbws@foxmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */

import PlatformView, { Params } from '@ohos/flutter_ohos/src/main/ets/plugin/platform/PlatformView';
import PlatformViewFactory from '@ohos/flutter_ohos/src/main/ets/plugin/platform/PlatformViewFactory';
import StandardMessageCodec from '@ohos/flutter_ohos/src/main/ets/plugin/common/StandardMessageCodec';
import Log from '@ohos/flutter_ohos/src/main/ets/util/Log';
import Any from '@ohos/flutter_ohos/src/main/ets/plugin/common/Any';
import common from '@ohos.app.ability.common';

const TAG = "MediaKitVideoPlatformView";

export const MEDIA_KIT_VIDEO_VIEW_TYPE: string = "com.alexmercerind/media_kit_video/view";

/**
 * XComponent controller that forwards surface lifecycle to the owning
 * [MediaKitVideoPlatformView].
 *
 * The surface is created asynchronously by ArkUI, so anything that needs the
 * surface ID (notably libmpv's --wid) has to wait for [onSurfaceCreated].
 */
class MediaKitXComponentController extends XComponentController {
  private owner: MediaKitVideoPlatformView;

  constructor(owner: MediaKitVideoPlatformView) {
    super();
    this.owner = owner;
  }

  onSurfaceCreated(surfaceId: string): void {
    Log.i(TAG, `onSurfaceCreated: ${surfaceId}`);
    this.owner.onSurfaceCreated(surfaceId);
  }

  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    Log.i(TAG, `onSurfaceChanged: ${surfaceId} ${rect.surfaceWidth}x${rect.surfaceHeight}`);
  }

  onSurfaceDestroyed(surfaceId: string): void {
    Log.i(TAG, `onSurfaceDestroyed: ${surfaceId}`);
    this.owner.onSurfaceDestroyed();
  }
}

@Builder
function buildMediaKitVideoView(params: Params) {
  XComponent({
    id: (params.platformView as MediaKitVideoPlatformView).getViewId().toString(),
    type: XComponentType.SURFACE,
    controller: (params.platformView as MediaKitVideoPlatformView).getXComponentController()
  })
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    // Under Hybrid Composition (HCPP) this view is stacked above the Flutter
    // surface, so touches and wheel events on the bare video land here rather
    // than in Flutter. Hand them back so the player's gestures keep working.
    // The engine installs the dispatchers when it creates the view and clears
    // them on dispose.
    .onTouch((event: TouchEvent) => {
      const view: PlatformView = params.platformView;
      const dispatch = view.touchDispatcher;
      if (dispatch != null) {
        dispatch(view.ohosHcppViewId, event);
      }
    })
    .onAxisEvent((event: AxisEvent) => {
      const view: PlatformView = params.platformView;
      const dispatch = view.axisDispatcher;
      if (dispatch != null) {
        dispatch(view.ohosHcppViewId, event);
      }
    })
}

/**
 * Hosts the video surface in a native XComponent instead of a Flutter
 * texture.
 *
 * This exists for HDR. A Flutter texture is resampled into the Flutter
 * surface before it reaches the screen, which drops the colour space and HDR
 * metadata that libmpv attaches to its NativeWindow, so HarmonyOS never
 * enters HDR mode. An XComponent inside a hybrid-composition platform view is
 * handed to the render service directly, keeping that metadata intact.
 */
export class MediaKitVideoPlatformView extends PlatformView {
  private viewId: number;
  private controller: MediaKitXComponentController;
  private surfaceId: string = '';
  // Resolvers waiting for the surface to come up. Settled with null if the
  // view is disposed first.
  private pending: Array<(surfaceId: string | null) => void> = [];

  constructor(viewId: number) {
    super();
    this.viewId = viewId;
    this.controller = new MediaKitXComponentController(this);
  }

  getType(): string {
    return MEDIA_KIT_VIDEO_VIEW_TYPE;
  }

  getView(): WrappedBuilder<[Params]> {
    return wrapBuilder(buildMediaKitVideoView);
  }

  getViewId(): number {
    return this.viewId;
  }

  getXComponentController(): MediaKitXComponentController {
    return this.controller;
  }

  onSurfaceCreated(surfaceId: string): void {
    this.surfaceId = surfaceId;
    const waiting = this.pending;
    this.pending = [];
    waiting.forEach((resolve: (surfaceId: string | null) => void) => resolve(surfaceId));
  }

  onSurfaceDestroyed(): void {
    this.surfaceId = '';
  }

  /**
   * Resolves with the XComponent's surface ID, waiting for surface creation
   * if it has not happened yet. Resolves with null if the view is disposed
   * before it ever gets a surface.
   */
  awaitSurfaceId(): Promise<string | null> {
    if (this.surfaceId.length > 0) {
      return Promise.resolve(this.surfaceId);
    }
    return new Promise<string | null>((resolve: (surfaceId: string | null) => void) => {
      this.pending.push(resolve);
    });
  }

  dispose(): void {
    // Leaving fullscreen right after entering it disposes the view before
    // ArkUI creates its surface. Dropping the waiters would leave the Dart
    // side's PlatformView.GetSurfaceId call unanswered forever; null is what
    // it already reads as "no surface".
    const waiting = this.pending;
    this.pending = [];
    waiting.forEach((resolve: (surfaceId: string | null) => void) => resolve(null));
    this.surfaceId = '';
  }
}

export class MediaKitVideoPlatformViewFactory extends PlatformViewFactory {
  // Views are kept so that the plugin can resolve a surface ID from the view
  // ID that the Dart side knows about.
  private views: Map<number, MediaKitVideoPlatformView> = new Map();

  constructor() {
    super(StandardMessageCodec.INSTANCE);
  }

  create(context: common.Context, viewId: number, args: Any): PlatformView {
    Log.i(TAG, `create: ${viewId}`);
    const view = new MediaKitVideoPlatformView(viewId);
    this.views.set(viewId, view);
    return view;
  }

  getView(viewId: number): MediaKitVideoPlatformView | undefined {
    return this.views.get(viewId);
  }

  removeView(viewId: number): void {
    this.views.get(viewId)?.dispose();
    this.views.delete(viewId);
  }
}
