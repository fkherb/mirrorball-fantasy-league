import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('photos', Path(__file__).parents[1] / 'Automations/dwts-photos.py')
photos = importlib.util.module_from_spec(spec)
spec.loader.exec_module(photos)
COUPLE = {'star_name': 'Amber Glenn', 'pro_name': 'Pasha Pashkov'}
POST = {'id_str': '123', 'created_at': 'Tue Oct 06 20:30:00 +0000 2026',
        'full_text': 'Amber Glenn and Pasha Pashkov'}


class PhotoDiagnosticsTests(unittest.TestCase):
    def run_fixture(self, posts, files=None, failure=None, dry_run=False):
        with patch.object(photos, 'fetch_posts', side_effect=failure, return_value=posts), \
             patch.object(photos, 'remote_files', return_value=[]), \
             patch.object(photos, 'download', return_value=files or []), \
             patch.object(photos, 'commit_files', return_value='a' * 40) as upload:
            result = photos.run(4, [COUPLE], 'private-token', since='2026-10-06',
                dry_run=dry_run, external_state={'downloaded': {}})
            if not files or dry_run:
                upload.assert_not_called()
        return result

    def test_empty_timeline_and_unmatched_posts(self):
        self.assertEqual(self.run_fixture([])['diagnostics']['outcome'], 'empty_timeline')
        d = self.run_fixture([{**POST, 'full_text': 'Welcome to the ballroom!'}])['diagnostics']
        self.assertEqual(d['unmatched_posts'], 1)
        self.assertEqual(d['outcome'], 'no_matching_posts')

    def test_stale_posts_are_distinct(self):
        d = self.run_fixture([{**POST, 'created_at': 'Tue Sep 29 20:30:00 +0000 2026'}])['diagnostics']
        self.assertEqual(d['before_since_posts'], 1)
        self.assertEqual(d['outcome'], 'no_recent_posts')

    def test_empty_downloads_are_visible_not_successes(self):
        result = self.run_fixture([POST])
        d = result['diagnostics']
        self.assertEqual(d['matched_posts'], 1)
        self.assertEqual(d['empty_downloads'], 1)
        self.assertEqual(d['outcome'], 'no_images_downloaded')
        self.assertEqual(d['post_results'][0]['status'], 'no_images')
        self.assertEqual(result['uploaded_couples'], [])
        self.assertEqual(result['remaining_couples'], [COUPLE])

    def test_upload_has_correct_counts(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / 'photo.jpg'
            image.write_bytes(b'test fixture')
            result = self.run_fixture([POST], [image])
        self.assertEqual(result['diagnostics']['outcome'], 'uploaded')
        self.assertEqual(result['diagnostics']['uploaded_files'], 1)
        self.assertEqual(result['diagnostics']['pending_couples'], 0)

    def test_preview_does_not_count_upload(self):
        result = self.run_fixture([POST], dry_run=True)
        self.assertEqual(result['diagnostics']['outcome'], 'preview_matches')
        self.assertEqual(result['diagnostics']['uploaded_files'], 0)
        self.assertEqual(result['diagnostics']['download_attempts'], 0)

    def test_rate_limit_and_skip_next_run(self):
        result = self.run_fixture([], failure=photos.RateLimitError('X', 650))
        self.assertTrue(result['failed_run'])
        self.assertTrue(result['skip_next_run'])
        self.assertEqual(result['diagnostics']['outcome'], 'rate_limited')

    def test_warning_classification_hides_raw_auth_logs(self):
        process = subprocess.CompletedProcess([], 0, '', '[twitter][warning] Login required auth_token=PRIVATE')
        d = photos.new_result(4, [COUPLE], False)['diagnostics']
        with tempfile.TemporaryDirectory() as tmp, \
             patch.object(photos, 'gallery_command', return_value=['fake-gallery']), \
             patch.object(photos.subprocess, 'run', return_value=process):
            self.assertEqual(photos.download('https://x.com/officialdwts/status/123', tmp, d), [])
        self.assertEqual(d['warnings'], ['login_required'])
        self.assertNotIn('PRIVATE', str(d))

    def test_ambiguous_and_previously_processed_posts(self):
        other = {'star_name': 'Connor Wood', 'pro_name': 'Rylee Arnold'}
        with patch.object(photos, 'fetch_posts', return_value=[{**POST, 'full_text': POST['full_text'] + ' Connor Wood and Rylee Arnold'}]), \
             patch.object(photos, 'remote_files', return_value=[]), patch.object(photos, 'download') as download:
            result = photos.run(4, [COUPLE, other], 'token', since='2026-10-06', external_state={'downloaded': {}})
            self.assertEqual(result['diagnostics']['ambiguous_posts'], 1)
            download.assert_not_called()
        with patch.object(photos, 'fetch_posts', return_value=[POST]), patch.object(photos, 'remote_files', return_value=[]):
            result = photos.run(4, [COUPLE], 'token', since='2026-10-06', external_state={'downloaded': {'123': {}}})
        self.assertEqual(result['diagnostics']['already_seen_posts'], 1)

    def test_no_images_and_skipped_video_files(self):
        process = subprocess.CompletedProcess([], 0, '', '')
        d = photos.new_result(4, [COUPLE], False)['diagnostics']
        with tempfile.TemporaryDirectory() as tmp, patch.object(photos, 'gallery_command', return_value=['fake']), \
             patch.object(photos.subprocess, 'run', return_value=process):
            (Path(tmp) / 'video.mp4').write_bytes(b'fixture')
            self.assertEqual(photos.download('https://x.com/officialdwts/status/123', tmp, d), [])
        self.assertEqual(d['non_image_files'], 1)


if __name__ == '__main__':
    unittest.main()
