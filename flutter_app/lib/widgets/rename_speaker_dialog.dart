import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/speaker_controller.dart';

/// Shared by both entry points of the "optional at connect, always
/// changeable later" naming design: SearchingOverlay's "Connect" button
/// (skippable, [isInitialSetup]: true) and a speaker's own rename action
/// anytime after ([isInitialSetup]: false). Actually renames the speaker
/// hardware itself - see SpeakerController.renameSpeaker's own doc comment
/// for why this isn't just a local, app-only display override.
Future<void> showRenameSpeakerDialog(
  BuildContext context,
  SpeakerSession session, {
  bool isInitialSetup = false,
}) async {
  final controller = context.read<SpeakerController>();
  final nameCtrl = TextEditingController(text: isInitialSetup ? '' : session.speaker.name);
  final name = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: const Color(0xFF161616),
      title: Text(isInitialSetup ? 'Name this speaker?' : 'Rename Speaker'),
      content: TextField(
        controller: nameCtrl,
        autofocus: true,
        decoration: InputDecoration(hintText: isInitialSetup ? 'e.g. Living Room' : session.speaker.name),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(isInitialSetup ? 'Skip' : 'Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(nameCtrl.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (name == null || name.isEmpty) return;
  await controller.renameSpeaker(session, name);
}
