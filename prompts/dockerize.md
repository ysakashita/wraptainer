CLAUDE.md に定義されたコンテナ化ポリシーに従ってください。

提供された設計ドキュメントとソースコードをもとに、本番品質の Dockerfile を生成してください。

## ビルドスクリプトの優先利用

ソースコードのルートに `Makefile` や `build.sh` 等のビルドスクリプトが存在する場合は、ビルドツール（mvn / gradle / npm 等）を Dockerfile 内で直接呼び出さず、そのスクリプトを使用すること。例:

```
# Makefile がある場合
COPY Makefile .
RUN make build

# build.sh がある場合
COPY build.sh .
RUN chmod +x build.sh && ./build.sh
```

## Java / Tomcat ベースイメージの注意点

- JDK 17 以降、`tomcat:X.Y-jdk<version>-alpine` タグは Docker Hub に存在しない
- WAR をデプロイする場合は `tomcat:10.1-jdk21-temurin`（Ubuntu ベース）を使用すること
- alpine を強制したい場合は `eclipse-temurin:<version>-jre-alpine` に Tomcat を手動インストールするか、JAR 形式（Spring Boot embedded server 等）に切り替えること

## 出力フォーマット

Dockerfile の内容のみを stdout に直接出力してください。ファイル書き込みツールは使用しないでください。Markdown のコードフェンスで囲まないでください。ファイル内容の前後に説明文を含めないでください。
