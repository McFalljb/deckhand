# Update test fixtures

`test-key.txt` is a **throwaway** Ed25519 key (base64 seed) for the updater's tests
(`src/update_test.odin`, `tests/scripts/update.sh`). It is public on purpose. Its public half is
`UPDATE_TEST_PUBLIC_KEY` in `src/update_key.odin`, which Deckhand accepts only in test mode. It is
not the release key and signs nothing that ships.
