# [변경: 2026-08-28 17:10, 김병현 수정] EntryJS 배포용 Dockerfile 추가.
# 로컬 개발(PM2)은 계속 `npm run serve`(webpack dev server, 8080)를 쓰고,
# 이 Dockerfile 은 배포용 정적 빌드만 담당한다.
#
# 이 repo 는 라이브러리라서 "완성된 웹페이지"가 따로 없다. 화면은 example/example.ejs
# 라는 예제 템플릿이 전부이고, 그 템플릿을 실제 HTML 로 만들어 주는 설정이
# webpack_config/serve.js 하나뿐이다. 그래서 배포 빌드도 NODE_ENV=serve 로 돌린다.
# (부작용: serve 설정은 mode 가 development 라 번들이 압축되지 않아 용량이 크다.
#  압축본이 필요하면 prod 설정에도 HtmlWebpackPlugin 을 붙여야 한다.)
FROM node:20 AS builder

# pnpm-lock.yaml(v9) 을 쓰는 repo 라 pnpm 으로 설치한다
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable && corepack prepare pnpm@9 --activate

WORKDIR /app

# 의존성 먼저 설치해서 소스가 바뀌어도 이 레이어는 캐시가 살아있게 한다
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

# 소스 복사 후 빌드 (결과물은 dist 에 떨어진다: entry.js, entry.css, dist/index.html)
COPY . .
RUN NODE_ENV=serve pnpm exec webpack

# 생성된 index.html 의 자산 경로를 "상대경로"로 바꾼다.
#   Caddy/Ingress 가 /entryjs 접두사를 떼고 넘기므로, 브라우저 주소는 /entryjs/ 인데
#   HTML 안이 /dist/entry.js 같은 절대경로면 접두사가 빠진 곳을 찾아가 404 가 난다.
#   상대경로로 바꾸면 /entryjs/ 기준으로 풀려서 접두사가 그대로 붙는다.
#   - "../extern/…", "../js/…"  →  "extern/…", "js/…"  (index.html 을 루트에 두므로)
#   - "/dist/…"                 →  "dist/…"
#   - PUBLIC_PATH_FOR_ENTRYJS   →  런타임 chunk 로딩 경로 (src/entry.js 1행이 읽는다)
RUN sed -i \
      -e 's#"\.\./#"#g' \
      -e 's#="/dist/#="dist/#g' \
      -e "s#'lib/entry-js/dist/'#'dist/'#" \
      dist/index.html

FROM nginx:alpine AS production

# Caddy 가 entryjs:9005 로 프록시하므로 nginx 도 9005 에서 듣게 맞춘다
RUN sed -i 's/listen\( *\)80;/listen\19005;/' /etc/nginx/conf.d/default.conf

# index.html 은 루트에, 나머지는 HTML 이 참조하는 이름 그대로 둔다.
#   extern/ : 언어팩(lang/ko.js), 유틸(util/static.js), AI 워커·wasm·모델
#   js/     : lodash 등 예제가 직접 부르는 스크립트
COPY --from=builder /app/dist        /usr/share/nginx/html/dist
COPY --from=builder /app/extern      /usr/share/nginx/html/extern
COPY --from=builder /app/js          /usr/share/nginx/html/js
COPY --from=builder /app/dist/index.html /usr/share/nginx/html/index.html

EXPOSE 9005

CMD ["nginx", "-g", "daemon off;"]
