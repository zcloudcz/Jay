# Acceptance: delete chats and contacts, leave groups

Spec: `docs/superpowers/specs/2026-11-09-delete-chats-contacts.md`. Branch `feat/delete-chats`. Automated coverage: `calltype/test/features/chat/delete_chats_flow_test.dart`, `delete_chats_widgets_test.dart`, `calltype_protocol/test/messaging/chat_deleted_test.dart`, server `GroupEndpointsTests` / `BusinessGroupEndpointsTests`. None of the scenarios below was run by hand yet.

| # | Scenario | Steps | Expected | Status |
|---|---|---|---|---|
| 1 | Delete a 1:1 chat on the phone, gone on the web too | Phone and linked web both show the chat with Bob. On the phone: long press the chat (or swipe left) -> Delete chat -> confirm. | The chat disappears on the phone and, within seconds, on the web. Bob still has all messages. Notifications of that chat are gone on both. | NOT_RUN |
| 2 | A new message after the delete recreates the chat | After 1, Bob writes "hi". | The chat appears again on the phone and the web with only "hi", unread 1. | NOT_RUN |
| 3 | Delete a contact, synced to the other device | Contacts -> Bob -> menu -> Delete contact, keep "Also delete the chat" ticked -> confirm. | Bob is gone from the contacts on the phone and the web, the chat is gone on both. Bob is not blocked: his next message still arrives (as a non-contact chat). | NOT_RUN |
| 4 | Leave a group | In a group created by somebody else: open it -> menu -> Leave group -> confirm. Then let another member write in it. | The chat is gone on the phone and the web; the other members see the member list without you; their new messages no longer arrive. As the group's only admin the app says you cannot leave and deletes nothing. | NOT_RUN |
| 5 | Business chat dialog | Long press a business conversation -> Delete chat. | The dialog says the organization's archive is not affected. Deleting removes it locally only; the archive (auditor) is unchanged. | NOT_RUN |
| 6 | Bot chat with a removed bot | Remove a test bot with `jay-new-bot --remove`, then delete its chat and its contact in the app. | Both go away like for any other chat/contact; no error although the bot's identity no longer exists. | NOT_RUN |
