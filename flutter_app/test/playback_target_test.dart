import 'package:flutter_test/flutter_test.dart';

import 'package:soundtech_air/models/group_info.dart';
import 'package:soundtech_air/models/speaker_info.dart';
import 'package:soundtech_air/state/speaker_controller.dart';

SpeakerSession _session(String id, String ip) {
  return SpeakerSession(SpeakerInfo(ip: ip, deviceId: id, name: 'Speaker $id'));
}

GroupInfo _group({required String masterId, required String leftId, required String rightId}) {
  return GroupInfo(
    id: 'g1',
    name: '',
    masterDeviceId: masterId,
    roles: [
      GroupRole(deviceId: leftId, role: StereoRole.left, ipAddress: '10.0.0.1'),
      GroupRole(deviceId: rightId, role: StereoRole.right, ipAddress: '10.0.0.2'),
    ],
  );
}

void main() {
  group('SpeakerController.playbackTargets', () {
    test('two mutually-paired sessions collapse into one paired target', () {
      final controller = SpeakerController();
      final a = _session('A', '10.0.0.1');
      final b = _session('B', '10.0.0.2');
      a.group = _group(masterId: 'A', leftId: 'A', rightId: 'B');
      b.group = _group(masterId: 'A', leftId: 'A', rightId: 'B');
      controller.sessions = [a, b];

      final targets = controller.playbackTargets;

      expect(targets.length, 1);
      expect(targets.single.isPaired, true);
      expect(targets.single.left.id, 'A');
      expect(targets.single.right.id, 'B');
      expect(targets.single.commandTarget.id, 'A');
    });

    test('commandTarget follows masterDeviceId even when master is the RIGHT role', () {
      final controller = SpeakerController();
      final a = _session('A', '10.0.0.1');
      final b = _session('B', '10.0.0.2');
      // B is master despite being the RIGHT-role member - a pair created
      // outside this app could have either role as master.
      a.group = _group(masterId: 'B', leftId: 'A', rightId: 'B');
      b.group = _group(masterId: 'B', leftId: 'A', rightId: 'B');
      controller.sessions = [a, b];

      final target = controller.playbackTargets.single;
      expect(target.commandTarget.id, 'B');
      expect(target.left.id, 'A');
      expect(target.right.id, 'B');
    });

    test('3 sessions, 2 paired + 1 solo -> exactly 2 targets, no double-emitted slave', () {
      final controller = SpeakerController();
      final a = _session('A', '10.0.0.1');
      final b = _session('B', '10.0.0.2');
      final c = _session('C', '10.0.0.3');
      a.group = _group(masterId: 'A', leftId: 'A', rightId: 'B');
      b.group = _group(masterId: 'A', leftId: 'A', rightId: 'B');
      // c.group stays null - solo.
      controller.sessions = [a, b, c];

      final targets = controller.playbackTargets;

      expect(targets.length, 2);
      final paired = targets.where((t) => t.isPaired).toList();
      final solos = targets.where((t) => !t.isPaired).toList();
      expect(paired.length, 1);
      expect(solos.length, 1);
      expect(solos.single.solo.id, 'C');
      // B must not also appear as its own solo target.
      expect(targets.any((t) => !t.isPaired && t.solo.id == 'B'), false);
    });

    test('one-sided pairing claim (not reciprocated) falls back to two solos', () {
      final controller = SpeakerController();
      final a = _session('A', '10.0.0.1');
      final b = _session('B', '10.0.0.2');
      // A claims B as a partner, but B's own poll hasn't landed yet (still
      // null) - simulates the transitional window right after an external
      // unpair, or right before a pair the app didn't create is discovered.
      a.group = _group(masterId: 'A', leftId: 'A', rightId: 'B');
      b.group = null;
      controller.sessions = [a, b];

      final targets = controller.playbackTargets;

      expect(targets.length, 2);
      expect(targets.every((t) => !t.isPaired), true);
    });

    test('master unreachable for 2+ polls splits a pair back into two solos', () {
      final controller = SpeakerController();
      final a = _session('A', '10.0.0.1');
      final b = _session('B', '10.0.0.2');
      a.group = _group(masterId: 'A', leftId: 'A', rightId: 'B');
      b.group = _group(masterId: 'A', leftId: 'A', rightId: 'B');
      a.unreachableStreak = 2;
      controller.sessions = [a, b];

      final targets = controller.playbackTargets;

      expect(targets.length, 2);
      expect(targets.every((t) => !t.isPaired), true);
    });

    test('slave unreachable does not split the pair', () {
      final controller = SpeakerController();
      final a = _session('A', '10.0.0.1');
      final b = _session('B', '10.0.0.2');
      a.group = _group(masterId: 'A', leftId: 'A', rightId: 'B');
      b.group = _group(masterId: 'A', leftId: 'A', rightId: 'B');
      b.unreachableStreak = 5;
      controller.sessions = [a, b];

      final targets = controller.playbackTargets;

      expect(targets.length, 1);
      expect(targets.single.isPaired, true);
      expect(targets.single.commandTarget.id, 'A');
    });

    test('solo sessions with no group at all are unaffected', () {
      final controller = SpeakerController();
      final a = _session('A', '10.0.0.1');
      final b = _session('B', '10.0.0.2');
      controller.sessions = [a, b];

      final targets = controller.playbackTargets;

      expect(targets.length, 2);
      expect(targets.every((t) => !t.isPaired), true);
    });
  });
}
