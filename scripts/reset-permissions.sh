#!/bin/bash
# Reset TCC permissions for Managerie
# After running, relaunch the app to re-grant permissions via macOS prompts.

BUNDLE_ID="com.managerie.app"

echo "Resetting TCC permissions for $BUNDLE_ID..."

tccutil reset Accessibility "$BUNDLE_ID"
tccutil reset Microphone "$BUNDLE_ID"
tccutil reset All "$BUNDLE_ID"

echo "Done! Relaunch Managerie to re-grant permissions."
