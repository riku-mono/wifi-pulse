# Name and icon policy

The source code of Wi-Fi Pulse is licensed under the [Apache License 2.0](LICENSE).
The **name “Wi-Fi Pulse”** and the **app icon** are not: they remain © riku-mono, all rights reserved. This covers:

- the name “Wi-Fi Pulse” and anything confusingly similar
- `apps/macos/WiFiPulse/Resources/AppIcon.icon`
- the images in [`assets/`](assets/)

This keeps users from confusing a modified build with the official app.

## You may

- Say that your project is based on, forked from or compatible with Wi-Fi Pulse, in plain text.
- Use the name and icon to talk about the official app — in articles, reviews, tutorials and links to this repository.
- Build the app from this repository for your own use without changing anything.

## Please don't, without permission

- Distribute a modified build, or any build you made yourself, under the name “Wi-Fi Pulse” or with the app icon.
- Use the name or icon in a way that suggests endorsement by, or affiliation with, the project.

## If you distribute a fork

1. Choose a different name and set it in `INFOPLIST_KEY_CFBundleDisplayName`.
2. Replace `AppIcon.icon` with your own icon, and don't ship the images in `assets/`.
3. Change the bundle identifier (`me.riku-mono.WiFiPulse`) and the log subsystem to your own domain.
4. Keep `LICENSE` and `NOTICE`, as the Apache License requires.

Questions: open an issue or contact [@riku-mono](https://github.com/riku-mono).

---

## 日本語の要約

コードは Apache License 2.0 ですが、**「Wi-Fi Pulse」の名前とアプリアイコン（`AppIcon.icon`・`assets/` の画像）は All rights reserved** です。

- **してよいこと**:
  - 「Wi-Fi Pulse をもとにした」「互換がある」と文章で書く
  - 公式のアプリを紹介するために名前やアイコンを使う
  - 手を加えずに自分用にビルドする
- **許可が必要なこと**:
  - 改変した版や自分でビルドした版を、この名前やアイコンで配る
  - 公式と関係があるように見せる
- **フォークを配るとき**:
  - 名前・アイコン・Bundle ID を自分のものに変える
  - `LICENSE` と `NOTICE` は残す
