import json
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from bookmarks import Store, fetch_snapshot, poll, deliver, CaptureError, prompt_for, XApi, private_json, CodexBridge, resolve_delivery


def tweet(id):
    return {"id": str(id), "text": "Saved text", "author_id": "7"}


def page(*ids, next_token=None):
    return {"data": [tweet(i) for i in ids],
            "includes": {"users": [{"id": "7", "name": "Mike", "username": "mike"}]},
            "meta": {"result_count": len(ids), **({"next_token": next_token} if next_token else {})}}


class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = Store(pathlib.Path(self.tmp.name))
        self.addCleanup(self.store.close)

    def source(self, *pages):
        api = Mock()
        api.get.side_effect = [{"data": {"id": "42"}}, *pages]
        return api

    def test_baseline_all_pages_then_only_new_even_old_tweet_id(self):
        poll(self.store, self.source(page(99, next_token="next"), page(98)))
        self.assertEqual(self.store.counts(), {"baseline": 2})
        poll(self.store, self.source(page(1), page(1, 99, 98)))
        self.assertEqual(self.store.counts(), {"baseline": 2, "pending": 1})
        poll(self.store, self.source(page(1)))
        poll(self.store, self.source(page(99), page(99, 1)))
        self.assertEqual(self.store.counts(), {"baseline": 2, "pending": 1})

    def test_empty_baseline_is_durable(self):
        poll(self.store, self.source(page()))
        self.store.close()
        self.store = Store(pathlib.Path(self.tmp.name))
        self.addCleanup(self.store.close)
        poll(self.store, self.source(page(1), page(1)))
        self.assertEqual(self.store.counts(), {"pending": 1})

    def test_failed_or_partial_snapshot_never_advances_baseline(self):
        for bad in [{"errors": [{"detail": "partial"}]}, {}, {"data": [tweet(1)], "meta": {"result_count": 1}}]:
            with self.assertRaises(CaptureError):
                poll(self.store, self.source(bad))
            self.assertFalse(self.store.get("baseline"))
        api = self.source(page(1, next_token="next"))
        api.get.side_effect = [{"data": {"id": "42"}}, page(1, next_token="next"), OSError("offline")]
        with self.assertRaises(OSError):
            poll(self.store, api)
        self.assertEqual(self.store.counts(), {})

    def test_cycle_and_page_limit_fail_closed(self):
        api = Mock()
        api.get.return_value = page(1, next_token="same")
        with self.assertRaises(CaptureError):
            fetch_snapshot(api, "42", max_pages=5)
        with self.assertRaises(CaptureError):
            fetch_snapshot(api, "42", max_pages=1)

    def test_account_change_is_rejected(self):
        poll(self.store, self.source(page()))
        api = Mock()
        api.get.return_value = {"data": {"id": "43"}}
        with self.assertRaises(CaptureError):
            poll(self.store, api)
        self.assertEqual(api.get.call_count, 1)

    def seed(self):
        poll(self.store, self.source(page()))
        poll(self.store, self.source(page(1), page(1)))

    def test_unchanged_head_only_fetches_one_bookmark_without_authors(self):
        poll(self.store, self.source(page(99, 98)))
        self.store.close()
        self.store = Store(pathlib.Path(self.tmp.name))
        self.addCleanup(self.store.close)
        api = self.source({"data": [{"id": "99"}], "meta": {"result_count": 1}})
        poll(self.store, api)
        self.assertEqual(api.get.call_count, 2)  # Account check plus one bookmark.
        self.assertEqual(api.get.call_args.args[1], {"max_results": 1})
        self.assertEqual(self.store.get("latest_bookmark"), "99")

    def test_changed_head_uses_ten_and_pages_until_known(self):
        poll(self.store, self.source(page(99)))
        api = self.source(page(1), page(*range(1, 11), next_token="older"), page(11, 99, next_token="unused"))
        poll(self.store, api)
        self.assertEqual([call.args[1]["max_results"] for call in api.get.call_args_list[1:]], [1, 10, 10])
        self.assertEqual(api.get.call_args.args[1]["pagination_token"], "older")
        self.assertEqual(self.store.counts(), {"baseline": 1, "pending": 11})
        self.assertEqual(self.store.get("latest_bookmark"), "1")

    def test_processes_whole_boundary_page_when_known_item_moved_to_top(self):
        poll(self.store, self.source(page(99, 98)))
        poll(self.store, self.source(page(98), page(98, 1, 99, next_token="unused")))
        self.assertEqual(self.store.counts(), {"baseline": 2, "pending": 1})
        self.assertEqual(self.store.get("latest_bookmark"), "98")

    def test_failed_catchup_keeps_head_and_queue_for_retry(self):
        poll(self.store, self.source(page(99)))
        for last in [OSError("offline"), {"errors": [{"detail": "partial"}]}]:
            api = self.source(page(1), page(1, next_token="older"), last)
            with self.assertRaises((OSError, CaptureError)):
                poll(self.store, api)
            self.assertEqual(self.store.get("latest_bookmark"), "99")
            self.assertEqual(self.store.counts(), {"baseline": 1})
        poll(self.store, self.source(page(1), page(1, 99)))
        self.assertEqual(self.store.counts(), {"baseline": 1, "pending": 1})

    def test_catchup_limit_does_not_advance_head(self):
        poll(self.store, self.source(page(99)))
        with self.assertRaises(CaptureError):
            poll(self.store, self.source(page(1), page(1, next_token="older")), max_pages=1)
        self.assertEqual(self.store.get("latest_bookmark"), "99")

    def test_empty_head_and_legacy_state_do_not_rebaseline(self):
        poll(self.store, self.source(page(99)))
        poll(self.store, self.source(page()))
        self.assertEqual(self.store.get("latest_bookmark"), "")
        poll(self.store, self.source(page(99), page(99)))
        with self.store.db:
            self.store.db.execute("DELETE FROM metadata WHERE key='latest_bookmark'")
        poll(self.store, self.source(page(1), page(1, 99)))
        self.assertEqual(self.store.counts(), {"baseline": 1, "pending": 1})

    def test_invalid_probe_does_not_clear_head(self):
        poll(self.store, self.source(page(99)))
        for bad in [{}, {"meta": {"result_count": 0}, "errors": [{}]}, page(1, 2)]:
            with self.assertRaises(CaptureError):
                poll(self.store, self.source(bad))
            self.assertEqual(self.store.get("latest_bookmark"), "99")

    def test_head_is_taken_from_catchup_if_bookmarks_change_between_requests(self):
        poll(self.store, self.source(page(99)))
        poll(self.store, self.source(page(1), page(2, 1, 99)))
        self.assertEqual(self.store.get("latest_bookmark"), "2")
        self.assertEqual(self.store.counts(), {"baseline": 1, "pending": 2})

    def test_removed_boundary_scans_to_end_without_recreating_known_tasks(self):
        self.seed()
        poll(self.store, self.source(page(2), page(2, 3, next_token="older"), page(4)))
        self.assertEqual(self.store.counts(), {"pending": 4})
        self.assertEqual(self.store.get("latest_bookmark"), "2")

    def test_poll_never_opens_codex_and_delivery_is_once(self):
        self.seed()
        bridge = Mock()
        bridge.start.return_value = "thread-1"
        deliver(self.store, bridge)
        deliver(self.store, bridge)
        bridge.start.assert_called_once()
        bridge.submit.assert_called_once()
        self.assertEqual(self.store.counts(), {"delivered": 1})

    def test_unavailable_bridge_leaves_pending(self):
        self.seed()
        bridge = Mock()
        bridge.probe.side_effect = CaptureError("unavailable")
        with self.assertRaises(CaptureError):
            deliver(self.store, bridge)
        self.assertEqual(self.store.counts(), {"pending": 1})
        bridge.start.assert_not_called()

    def test_lost_create_response_is_never_retried_automatically(self):
        self.seed()
        bridge = Mock()
        bridge.start.side_effect = TimeoutError()
        with self.assertRaises(TimeoutError):
            deliver(self.store, bridge)
        deliver(self.store, bridge)
        bridge.start.assert_called_once()
        self.assertEqual(self.store.counts(), {"creating": 1})

    def test_lost_submit_response_is_never_retried_automatically(self):
        self.seed()
        bridge = Mock()
        bridge.start.return_value = "thread-1"
        bridge.submit.side_effect = TimeoutError()
        with self.assertRaises(TimeoutError):
            deliver(self.store, bridge)
        deliver(self.store, bridge)
        bridge.start.assert_called_once()
        bridge.submit.assert_called_once()
        self.assertEqual(self.store.counts(), {"submitting": 1})
        self.assertEqual(self.store.row("1")["thread_id"], "thread-1")

    def test_created_thread_is_reused_after_restart(self):
        self.seed()
        self.store.update("1", "created", "thread-1")
        bridge = Mock()
        deliver(self.store, bridge)
        bridge.start.assert_not_called()
        bridge.submit.assert_called_once()

    def test_long_text_and_untrusted_capture_prompt(self):
        p = page(1)
        p["data"][0]["note_tweet"] = {"text": "Full long tweet"}
        items = fetch_snapshot(Mock(get=Mock(return_value=p)), "42")
        text = prompt_for(items[0])
        self.assertIn("Full long tweet", text)
        self.assertIn("https://x.com/mike/status/1", text)
        self.assertIn("Mike", text)
        self.assertIn("untrusted", text)
        self.assertIn("Do not research", text)

    def test_exclusive_lock(self):
        with self.store.lock():
            with self.assertRaises(CaptureError):
                with self.store.lock():
                    self.fail("second lock acquired")

    def test_paid_api_disabled_before_any_network_or_token_read(self):
        with patch("bookmarks.request_json") as request:
            with self.assertRaises(CaptureError):
                XApi({"allow_paid_x_api": False})
            request.assert_not_called()

    def test_refresh_saves_rotated_credentials_before_read(self):
        token = pathlib.Path(self.tmp.name) / "token.json"
        private_json(token, {"access_token": "old", "refresh_token": "refresh-old", "expires_at": 0,
                             "scope": "bookmark.read tweet.read users.read offline.access"})
        with patch("bookmarks.request_json", side_effect=[
            {"access_token": "new", "refresh_token": "refresh-new", "expires_in": 7200}, page(1)
        ]) as request:
            api = XApi({"allow_paid_x_api": True, "token_file": str(token), "client_id": "public-app"})
            api.get("/users/42/bookmarks")
        self.assertEqual(json.loads(token.read_text())["refresh_token"], "refresh-new")
        self.assertEqual(token.stat().st_mode & 0o777, 0o600)
        self.assertEqual(request.call_args_list[1].args[1]["Authorization"], "Bearer new")

    def test_scopes_rejected(self):
        token = pathlib.Path(self.tmp.name) / "token.json"
        private_json(token, {"access_token": "fake", "scope": "tweet.read"})
        with self.assertRaises(CaptureError):
            XApi({"allow_paid_x_api": True, "token_file": str(token)})

    def test_bridge_uses_read_only_unique_folder_and_minimal_turn(self):
        rpc = Mock()
        rpc.call.return_value = {"thread": {"id": "thread-1"}}
        bridge = CodexBridge(rpc, {}, self.store)
        item = fetch_snapshot(Mock(get=Mock(return_value=page(1))), "42")[0]
        self.assertEqual(bridge.start(item), "thread-1")
        params = rpc.call.call_args.args[1]
        self.assertEqual(params["sandbox"], "read-only")
        self.assertEqual(pathlib.Path(params["cwd"]).name, "1")
        bridge.submit("thread-1", item)
        self.assertEqual(rpc.call.call_args.args[0], "turn/start")
        self.assertIn("Do not research", rpc.call.call_args.args[1]["input"][0]["text"])

    def test_manual_recovery_reuses_id_and_cannot_reset_known_task(self):
        self.seed()
        self.store.update("1", "creating")
        resolve_delivery(self.store, "1", "created-without-message", "thread-1")
        self.assertEqual(self.store.row("1")["status"], "created")
        self.store.update("1", "submitting")
        for outcome, task in [("not-created", None), ("captured", "different")]:
            with self.assertRaises(CaptureError):
                resolve_delivery(self.store, "1", outcome, task)
        resolve_delivery(self.store, "1", "captured", None)
        self.assertEqual(self.store.row("1")["thread_id"], "thread-1")
        self.assertEqual(self.store.counts(), {"delivered": 1})


if __name__ == "__main__":
    unittest.main()
