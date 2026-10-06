import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('worker', Path(__file__).parents[1] / 'Automations/dwts-worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.w = worker.Worker({'SUPABASE_URL': 'https://example.supabase.co',
            'DWTS_AUTOMATION_WORKER_SECRET': 's' * 48, 'DWTS_PHOTOS_GITHUB_TOKEN': 'private-token'},
            Path(self.tmp.name))

    def test_durable_redacted_outbox_and_retry(self):
        path = self.w.persist('run', {'error': 'private-token ' + 's' * 48})
        self.assertNotIn('private-token', path.read_text())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        with patch.object(self.w, 'api', side_effect=worker.ApiError(503, 'offline')):
            with self.assertRaises(worker.ApiError):
                self.w.flush(path)
        self.assertTrue(path.exists())
        with patch.object(self.w, 'api', return_value={}):
            self.w.flush(path)
        self.assertFalse(path.exists())

    def test_manual_github_photos_skip_x(self):
        target = {'dance_id': 'dance', 'star_name': 'Amber Glenn', 'pro_name': 'Pasha Pashkov'}
        task = {'run_id': 'run', 'mode': 'photos', 'week': 4, 'targets': [target], 'folder': 'Images/Dances/Week 4'}
        with patch.object(self.w.photos, 'remote_files', return_value=['Amber Glenn and Pasha Pashkov-1.avif']), \
             patch.object(self.w.photos, 'gh', return_value={'object': {'sha': 'a' * 40}}), \
             patch.object(self.w, 'api', return_value={'verified_dance_ids': ['dance']}), \
             patch.object(self.w.photos, 'fetch_posts') as fetch:
            result = self.w.photo_result(task)
        self.assertFalse(result['failed_run'])
        self.assertEqual(result['remaining_couples'], [])
        fetch.assert_not_called()

    def test_photo_receipts_and_external_state(self):
        photos = self.w.photos
        couple = {'star_name': 'Amber Glenn', 'pro_name': 'Pasha Pashkov'}
        post = {'id_str': '123', 'created_at': 'Tue Oct 06 20:30:00 +0000 2026',
            'full_text': 'Amber Glenn Pasha Pashkov'}
        local = Path(self.tmp.name) / 'photo.jpg'
        local.write_bytes(b'image fixture')
        with patch.object(photos, 'fetch_posts', return_value=[post, {**post, 'id_str': '124'}]), \
             patch.object(photos, 'remote_files', return_value=[]), \
             patch.object(photos, 'download', return_value=[local]) as download, \
             patch.object(photos, 'commit_files', return_value='a' * 40), \
             patch.object(photos, 'load_state') as load, patch.object(photos, 'save_state') as save:
            result = photos.run(4, [couple], 'token', since='2026-10-06', external_state={'downloaded': {}})
        self.assertFalse(result['failed_run'], result)
        receipt = result['uploaded_couples'][0]
        self.assertEqual(receipt['post_ids'], ['123'])
        self.assertEqual(receipt['commit_sha'], 'a' * 40)
        self.assertEqual(download.call_count, 1)
        load.assert_not_called()
        save.assert_not_called()

    def test_preview_never_reconciles_or_uploads(self):
        task = {'mode': 'photos', 'week': 3, 'targets': [{'star_name': 'Amber Glenn', 'pro_name': 'Pasha Pashkov'}]}
        with patch.object(self.w.photos, 'run', return_value={}) as run, patch.object(self.w, 'api') as api:
            self.w.gather(task, preview=True)
        self.assertTrue(run.call_args.kwargs['dry_run'])
        api.assert_not_called()

    def test_get_weeks_omits_couples(self):
        with patch.object(self.w.wiki, 'fetch_information', return_value={'weeks': []}) as fetch:
            self.w.gather({'mode': 'get-weeks', 'targets': []})
        fetch.assert_called_once_with('get-weeks')


if __name__ == '__main__':
    unittest.main()
