import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:vibration/vibration.dart';

/// Small shared helpers for every AR screen: translation with arguments,
/// unit formatting, haptics and the icon vocabulary.

/// Translates [key] and fills its `%a` slots in order (same helper shape as
/// `snagTr`). Arguments are stringified here so call sites pass numbers.
String arTr(BuildContext context, String key, [List<Object> args = const []]) {
  final text = key.getString(context);
  return args.isEmpty ? text : context.formatString(text, args.map((a) => '$a').toList());
}

/// Tablet layout from 900 logical px (CONTRACT C9).
const double kArTabletBreakpoint = 900;

bool arIsTablet(BoxConstraints c) => c.maxWidth >= kArTabletBreakpoint;

/// The AR camera screen's layouts. A phone turned sideways can be 900+ px
/// wide but only ~400 px tall: the tablet layout's rails and bottom card
/// don't fit it, the portrait phone's edge column and sheet don't either,
/// so it gets its own ([landscapePhone]).
enum ArLayout { phone, landscapePhone, tablet }

/// Tablet needs the width *and* some height; a short, wide view is a phone
/// on its side.
ArLayout arLayoutFor(Size view) {
  if (view.width >= kArTabletBreakpoint && view.height >= 600) return ArLayout.tablet;
  if (view.width > view.height) return ArLayout.landscapePhone;
  return ArLayout.phone;
}

/// The app is portrait-only (`main.dart`, and the manifest's
/// `screenOrientation="portrait"`, which `setPreferredOrientations`
/// overrides at runtime on Android). The AR camera screen alone may turn
/// sideways: a tablet on a tripod, a phone held level at a ceiling void.
/// Counted, because one AR screen can replace another (a board scan
/// replacing the session): the old screen's dispose runs *after* the new
/// one's init, and must not re-lock the new screen to portrait.
abstract final class ArOrientation {
  static var _holders = 0;

  static Future<void> enter() {
    _holders++;
    return _apply();
  }

  static Future<void> leave() {
    if (_holders > 0) _holders--;
    return _apply();
  }

  /// Portrait while another (portrait) screen is pushed over the AR one —
  /// the verification form, a snag — then back.
  static Future<void> pushPortrait() => SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  static Future<void> popBack() => _apply();

  static Future<void> _apply() async {
    try {
      await SystemChrome.setPreferredOrientations(
        _holders > 0
            ? const [DeviceOrientation.portraitUp, DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
            : const [DeviceOrientation.portraitUp],
      );
    } catch (_) {
      // No platform (a widget test): nothing to rotate.
    }
  }
}

/// "4.2 m" below 10 m, "12 m" above: a technician reads distance, not decimals.
String arMetres(BuildContext context, double m) {
  final v = m.abs() < 10 ? m.toStringAsFixed(1) : m.round().toString();
  return arTr(context, 'ar.unit.m', [v]);
}

/// "2 cm", never finer than a centimetre and never 0 (a lock is never perfect).
String arCentimetres(BuildContext context, double metres, {bool plusMinus = false}) {
  final cm = (metres * 100).abs();
  final v = cm < 1 ? '1' : (cm < 10 ? cm.toStringAsFixed(cm.roundToDouble() == cm ? 0 : 1) : cm.round().toString());
  return arTr(context, plusMinus ? 'ar.unit.pm_cm' : 'ar.unit.cm', [v]);
}

/// Signed nudge like "+1.5 cm".
String arSignedCentimetres(BuildContext context, double metres) {
  final cm = metres * 100;
  final v = cm.abs().toStringAsFixed(cm.abs() < 10 ? 1 : 0);
  return arTr(context, 'ar.unit.cm', ['${cm < 0 ? '−' : '+'}$v']);
}

/// "3.1 MB"; small packs show one decimal so "0.4 MB" isn't "0 MB".
String arMegabytes(BuildContext context, int bytes) {
  final mb = bytes / (1024 * 1024);
  final v = mb < 0.05 && bytes > 0 ? '0.1' : (mb < 100 ? mb.toStringAsFixed(1) : mb.round().toString());
  return arTr(context, 'ar.unit.mb', [v]);
}

/// Compass word for a horizontal direction in the tile frame, with −Z as
/// plan-up ("north"). Building north isn't known on the device, so this is
/// the model's plan-up, which is what the printed placement maps show too.
String arCompassKey(double nx, double nz) {
  // Heading from plan-up (−Z), clockwise towards +X.
  final angle = (math.atan2(nx, -nz) * 180 / math.pi + 360) % 360;
  const keys = [
    'ar.compass.north',
    'ar.compass.east',
    'ar.compass.south',
    'ar.compass.west',
  ];
  return keys[((angle + 45) ~/ 90) % 4];
}

/// The wall a board or face pointing ([nx], [nz]) is on: "west wall" for a
/// board that faces east into the room. Keys `ar.wall.*`.
String arWallKey(double nx, double nz) => switch (arCompassKey(-nx, -nz)) {
  'ar.compass.north' => 'ar.wall.north',
  'ar.compass.east' => 'ar.wall.east',
  'ar.compass.south' => 'ar.wall.south',
  _ => 'ar.wall.west',
};

/// Haptics that make snapping and locking *felt* (§2.3: "taps your hand when
/// it snaps"). A missing motor is never an error.
abstract final class ArHaptics {
  static Future<void> snap() async {
    await HapticFeedback.selectionClick();
  }

  static Future<void> lock() async {
    await HapticFeedback.mediumImpact();
    await _buzz(60);
  }

  static Future<void> success() async {
    await HapticFeedback.heavyImpact();
    await _buzz(120);
  }

  static Future<void> warn() async {
    await HapticFeedback.lightImpact();
  }

  static Future<void> _buzz(int ms) async {
    try {
      if (await Vibration.hasVibrator()) await Vibration.vibrate(duration: ms);
    } catch (_) {
      // Not worth reporting.
    }
  }
}

/// The AR icon vocabulary in one place, so a renamed Lucide glyph is a
/// one-line fix.
abstract final class ArIcons {
  static const back = LucideIcons.arrowLeft;
  static const close = LucideIcons.x;
  static const menu = LucideIcons.menu;
  static const focus = LucideIcons.focus;
  static const torch = LucideIcons.flashlight;
  static const torchOff = LucideIcons.flashlightOff;
  static const reSnap = LucideIcons.locateFixed;
  static const board = LucideIcons.qrCode;
  static const section = LucideIcons.scissors;
  static const measure = LucideIcons.ruler;
  static const layers = LucideIcons.layers;
  static const grid = LucideIcons.grid3x3;
  static const opacity = LucideIcons.eye;
  static const more = LucideIcons.slidersHorizontal;
  static const capture = LucideIcons.camera;
  static const single = LucideIcons.circleDot;
  static const multi = LucideIcons.checkCheck;
  static const lasso = LucideIcons.lasso;
  static const locate = LucideIcons.locateFixed;
  static const verify = LucideIcons.badgeCheck;
  static const progress = LucideIcons.chartColumn;
  static const snags = LucideIcons.flag;
  static const forms = LucideIcons.clipboardList;
  static const corner = LucideIcons.scanLine;
  static const gridCrossing = LucideIcons.grid3x3;
  static const resume = LucideIcons.history;
  static const gnss = LucideIcons.globe;
  static const lock = LucideIcons.lock;
  static const plan = LucideIcons.map;
  static const saveView = LucideIcons.star;
  static const share = LucideIcons.send;
  static const sync = LucideIcons.refreshCw;
  static const changeFloor = LucideIcons.building2;
  static const fineTune = LucideIcons.slidersHorizontal;
  static const realign = LucideIcons.rotateCcw;
  static const download = LucideIcons.cloudDownload;
  static const onDevice = LucideIcons.smartphone;
  static const warning = LucideIcons.triangleAlert;
  static const info = LucideIcons.info;
  static const check = LucideIcons.check;
  static const minus = LucideIcons.minus;
  static const plus = LucideIcons.plus;
  static const search = LucideIcons.search;
  static const demo = LucideIcons.sparkles;
  static const celebrate = LucideIcons.partyPopper;
  static const pin = LucideIcons.mapPin;
  static const offline = LucideIcons.cloudOff;
  static const identify = LucideIcons.scanEye;
  static const install = LucideIcons.hammer;
  static const swap = LucideIcons.arrowUpDown;
  static const level = LucideIcons.equal;
  static const photo = LucideIcons.image;
  static const next = LucideIcons.arrowRight;
  static const door = LucideIcons.doorOpen;
  static const building = LucideIcons.building2;
  static const box = LucideIcons.box;
  static const help = LucideIcons.circleHelp;
  static const external = LucideIcons.externalLink;
  static const drill = LucideIcons.drill;
  static const xray = LucideIcons.glasses;
  static const crosshair = LucideIcons.crosshair;
  static const roomScan = LucideIcons.radar;
  static const legend = LucideIcons.palette;
  static const showAll = LucideIcons.eye;
  static const hidden = LucideIcons.eyeOff;
  static const expand = LucideIcons.chevronDown;
  static const collapse = LucideIcons.chevronUp;
  static const height = LucideIcons.moveVertical;
  static const run = LucideIcons.ruler;
  static const size = LucideIcons.circleDot;
  static const concealed = LucideIcons.brickWall;
  static const electrical = LucideIcons.zap;
  static const plumbing = LucideIcons.droplets;
  static const hvac = LucideIcons.fan;
  static const fire = LucideIcons.flame;
  static const controls = LucideIcons.cpu;
  static const otherMep = LucideIcons.cable;
  static const structure = LucideIcons.columns3;
  static const walls = LucideIcons.brickWall;

  /// Sunlight mode (high-contrast chrome for bright sites).
  static const sunlight = LucideIcons.sun;

  static IconData discipline(String d) => switch (d) {
    'mep' => LucideIcons.fan,
    'structure' => LucideIcons.brickWall,
    'fire' => LucideIcons.flame,
    _ => LucideIcons.house,
  };
}
