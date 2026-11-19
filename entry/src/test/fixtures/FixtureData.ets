/**
 * FixtureData.ets —— fixtures/*.json 的内联副本（自动生成，请勿手改）
 *
 * 生成命令：node scripts/gen-fixtures.mjs
 * 来源目录：fixtures/（真实抓包 + 依据首方前端字段用法派生的样例，见 fixtures/README.md）
 */

/** 对应 fixtures/account-favorites.success.derived.json */
export const ACCOUNT_FAVORITES_SUCCESS_DERIVED: string = "{\n  \"status\": \"ok\",\n  \"data\": [\n    {\n      \"Bid\": 810001,\n      \"Bookname\": \"账号收藏範例 A\",\n      \"Author\": \"作者 A\",\n      \"Ptag\": \"標籤一 標籤二\",\n      \"Favorites\": 12,\n      \"Status\": 0,\n      \"F\": true\n    },\n    {\n      \"Bid\": 810002,\n      \"Bookname\": \"账号收藏範例 B\",\n      \"Author\": \"作者 B\"\n    }\n  ],\n  \"count\": 42\n}\n";

/** 对应 fixtures/ads.empty.derived.json */
export const ADS_EMPTY_DERIVED: string = "{\n  \"status\": \"ok\",\n  \"data\": []\n}\n";

/** 对应 fixtures/ads.success.derived.json */
export const ADS_SUCCESS_DERIVED: string = "{\n  \"status\": \"ok\",\n  \"data\": [\n    {\n      \"img\": \"https://img.noymanga.com/ads/1.webp\",\n      \"url\": \"https://example.com/promo/1\"\n    },\n    {\n      \"img\": \"http://cdn.example.com/ads/2.webp\",\n      \"url\": \"javascript:alert(1)\"\n    },\n    {\n      \"img\": \"ftp://bad.example/3.webp\",\n      \"url\": \"\"\n    },\n    {\n      \"img\": \"\",\n      \"url\": \"https://example.com/noimg\"\n    }\n  ]\n}\n";

/** 对应 fixtures/badge.success.derived.json */
export const BADGE_SUCCESS_DERIVED: string = "{\n  \"status\": \"ok\",\n  \"data\": [\n    {\n      \"Id\": 8,\n      \"Name\": \"徽章八\",\n      \"Img\": \"https://bucket.noymanga.com/image/b8.webp\",\n      \"Minimg\": \"https://bucket.noymanga.com/image/b8-min.webp\",\n      \"Des\": \"說明八\"\n    },\n    {\n      \"Id\": 9,\n      \"Name\": \"徽章九\",\n      \"Img\": \"https://bucket.noymanga.com/image/b9.webp\",\n      \"Minimg\": \"https://bucket.noymanga.com/image/b9-min.webp\",\n      \"Des\": \"說明九\"\n    },\n    {\n      \"Id\": 10,\n      \"Name\": \"徽章十\",\n      \"Img\": \"https://bucket.noymanga.com/image/b10.webp\",\n      \"Minimg\": \"https://bucket.noymanga.com/image/b10-min.webp\",\n      \"Des\": \"說明十\"\n    },\n    {\n      \"Id\": \"11\",\n      \"Name\": \"徽章十一\",\n      \"Img\": \"https://bucket.noymanga.com/image/b11.webp\",\n      \"Minimg\": \"https://bucket.noymanga.com/image/b11-min.webp\",\n      \"Des\": \"說明十一\"\n    }\n  ],\n  \"show\": [\"10\", \"11\", \"9\", \"8\"]\n}\n";

/** 对应 fixtures/book-comments.auth-required.json */
export const BOOK_COMMENTS_AUTH_REQUIRED: string = "{\"status\":\"login\"}\n";

/** 对应 fixtures/book-comments.success.derived.json */
export const BOOK_COMMENTS_SUCCESS_DERIVED: string = "{\n  \"status\": \"ok\",\n  \"data\": {\n    \"comments\": [\n      {\n        \"cid\": 1001,\n        \"uid\": 0,\n        \"username\": \"官方\",\n        \"content\": \"官方置頂公告（範例，非真實資料）\",\n        \"area\": \"官方公告\",\n        \"time\": 1735689600,\n        \"reply_num\": 0\n      },\n      {\n        \"cid\": \"1002\",\n        \"uid\": \"900007\",\n        \"username\": \"讀者甲\",\n        \"content\": \"畫風很棒\",\n        \"area\": \"China mainland\",\n        \"time\": 1735689700,\n        \"reply_num\": 2,\n        \"reply_more\": true,\n        \"replies\": [\n          {\n            \"cid\": 2001,\n            \"uid\": \"900008\",\n            \"username\": \"讀者乙\",\n            \"content\": \"同感\",\n            \"area\": \"China mainland\",\n            \"time\": 1735689800\n          }\n        ]\n      }\n    ],\n    \"page\": 1,\n    \"over\": false,\n    \"top_count\": 1\n  }\n}\n";

/** 对应 fixtures/book-detail.auth-required.json */
export const BOOK_DETAIL_AUTH_REQUIRED: string = "{\"status\":\"login\"}";

/** 对应 fixtures/book-detail.bad-types.derived.json */
export const BOOK_DETAIL_BAD_TYPES_DERIVED: string = "{\n  \"book\": {\n    \"info\": {\n      \"Bid\": 900303,\n      \"Bookname\": 12345,\n      \"Author\": { \"unexpected\": \"object\" },\n      \"Description\": [\"not\", \"a\", \"string\"],\n      \"alias\": 99,\n      \"Ptag\": 12345,\n      \"Pname\": 7,\n      \"Otag\": null,\n      \"RatingSUM\": \"not-a-number\",\n      \"RatingCount\": [],\n      \"Mode\": \"weird\",\n      \"Status\": \"unknown-status\",\n      \"publish_year\": {},\n      \"Time\": \"n/a\"\n    }\n  },\n  \"chapters\": {\n    \"categories\": \"not-an-array\",\n    \"data\": [1, 2, 3]\n  }\n}\n";

/** 对应 fixtures/book-detail.derived.json */
export const BOOK_DETAIL_DERIVED: string = "{\n  \"book\": {\n    \"info\": {\n      \"Bid\": 900201,\n      \"Bookname\": \"範例作品 C\",\n      \"Author\": \"範例作者 C\",\n      \"Description\": \"用於詳情解析測試的範例簡介（非真實資料）\",\n      \"Ptag\": [\"標籤丙\"],\n      \"Otag\": [],\n      \"Favorites\": 9,\n      \"RatingSUM\": 88,\n      \"RatingCount\": 5,\n      \"Mode\": 1\n    }\n  },\n  \"chapters\": {\n    \"categories\": [\n      { \"id\": 5, \"name\": \"第 1 卷\" },\n      { \"id\": 6, \"name\": \"第 2 卷\" }\n    ],\n    \"data\": {\n      \"5\": [\n        { \"id\": 90011, \"name\": \"第 2 話\", \"sort\": 2 },\n        { \"id\": 90010, \"name\": \"第 1 話\", \"sort\": 1 }\n      ],\n      \"6\": [\n        { \"id\": 90012, \"name\": \"第 3 話\", \"sort\": 3 }\n      ]\n    }\n  }\n}\n";

/** 对应 fixtures/book-detail.full.derived.json */
export const BOOK_DETAIL_FULL_DERIVED: string = "{\n  \"status\": \"ok\",\n  \"uid\": 900001,\n  \"book\": {\n    \"info\": {\n      \"Bid\": 900201,\n      \"Bookname\": \"範例作品 C\",\n      \"Author\": \"範例作者 C\",\n      \"Description\": \"用於詳情解析測試的範例簡介（非真實資料）\",\n      \"alias\": \"別名 C\",\n      \"Ptag\": [\"標籤甲\", \"標籤乙\"],\n      \"Pname\": [\"角色甲\"],\n      \"Otag\": [\"原作甲\"],\n      \"F\": false,\n      \"Favorites\": 9,\n      \"RatingSUM\": 88,\n      \"RatingCount\": 5,\n      \"Mode\": 1,\n      \"Status\": 1,\n      \"publish_year\": 2023,\n      \"Time\": 1735689600,\n      \"Len\": 12\n    },\n    \"recommend\": [\n      {\n        \"bid\": 900501,\n        \"bookname\": \"推薦範例 A\",\n        \"author\": \"推薦作者 A\",\n        \"tags\": \"熱血 冒險\",\n        \"views\": 120,\n        \"favorites\": 30,\n        \"mode\": true,\n        \"status\": false\n      },\n      {\n        \"bid\": \"900502\",\n        \"bookname\": \"推薦範例 B\"\n      },\n      {\n        \"bookname\": \"缺 bid 應丟棄\"\n      }\n    ]\n  },\n  \"comment\": {\n    \"count\": 2,\n    \"data\": [\n      {\n        \"cid\": 3001,\n        \"uid\": 0,\n        \"username\": \"官方\",\n        \"content\": \"官方置頂（範例，非真實資料）\",\n        \"area\": \"官方公告\",\n        \"time\": 1735689600\n      },\n      {\n        \"cid\": \"3002\",\n        \"uid\": \"900007\",\n        \"username\": \"讀者甲\",\n        \"content\": \"評論內容（範例）\",\n        \"area\": \"China mainland\",\n        \"time\": 1735689700,\n        \"reply_num\": 1,\n        \"replies\": [\n          {\n            \"cid\": 3101,\n            \"uid\": \"900008\",\n            \"username\": \"讀者乙\",\n            \"content\": \"回復內容\",\n            \"area\": \"China mainland\",\n            \"time\": 1735689800\n          }\n        ]\n      }\n    ]\n  },\n  \"points\": {\n    \"book_price\": \"0\",\n    \"user_balance\": \"100.5\"\n  },\n  \"chapters\": {\n    \"categories\": [\n      { \"id\": 5, \"name\": \"第 1 卷\" },\n      { \"id\": 6, \"name\": \"第 2 卷\" },\n      { \"id\": 7, \"name\": \"空分組\" }\n    ],\n    \"data\": {\n      \"5\": [\n        { \"id\": 90010, \"name\": \"第 2 话\", \"sort\": 2, \"count\": 20, \"created_at\": \"2024-01-02\" },\n        { \"id\": 90009, \"name\": \"第 10 话\", \"sort\": 10, \"count\": 18, \"created_at\": \"2024-01-10\" },\n        { \"id\": 90008, \"name\": \"第 1 话\", \"sort\": 1, \"count\": 22, \"created_at\": \"2024-01-01\" }\n      ],\n      \"6\": [\n        { \"id\": 90010, \"name\": \"第 3 话（跨組同 id）\", \"sort\": 3, \"count\": 15, \"created_at\": \"2024-02-03\" }\n      ],\n      \"7\": []\n    }\n  }\n}\n";

/** 对应 fixtures/book-detail.minimal.derived.json */
export const BOOK_DETAIL_MINIMAL_DERIVED: string = "{\n  \"book\": {\n    \"info\": {\n      \"Bid\": 900301,\n      \"Bookname\": \"最小欄位作品\"\n    }\n  }\n}\n";

/** 对应 fixtures/book-detail.single.derived.json */
export const BOOK_DETAIL_SINGLE_DERIVED: string = "{\n  \"book\": {\n    \"info\": {\n      \"Bid\": 900302,\n      \"Bookname\": \"單本作品\",\n      \"Mode\": 0\n    }\n  }\n}\n";

/** 对应 fixtures/booklist.success.derived.json */
export const BOOKLIST_SUCCESS_DERIVED: string = "{\n  \"info\": [\n    {\n      \"Bid\": 900201,\n      \"Bookname\": \"範例作品 C\",\n      \"Author\": \"範例作者 C\",\n      \"Description\": \"用於書單解析測試的範例條目（非真實資料）\",\n      \"Ptag\": \"標籤丙\",\n      \"Otag\": \"其他標籤\",\n      \"Views\": 100,\n      \"Favorites\": 9,\n      \"RatingSUM\": 88,\n      \"Adult\": 0,\n      \"Mode\": 1,\n      \"Status\": 0,\n      \"publish_year\": \"2023\",\n      \"Len\": 32\n    },\n    {\n      \"Bid\": \"900202\",\n      \"Bookname\": \"範例作品 D\",\n      \"Author\": \"範例作者 D\"\n    }\n  ],\n  \"len\": 21\n}\n";

/** 对应 fixtures/chapter-groups.derived.json */
export const CHAPTER_GROUPS_DERIVED: string = "{\n  \"categories\": [\n    { \"id\": \"a\", \"name\": \"分組 A\" },\n    { \"id\": \"b\" },\n    { \"id\": \"\", \"name\": \"無 id 分組\" }\n  ],\n  \"data\": {\n    \"a\": [\n      { \"id\": 1, \"name\": \"第 10 话\", \"sort\": 10 },\n      { \"id\": 2, \"name\": \"第 2 话\", \"sort\": 2 },\n      { \"id\": 3, \"sort\": 3, \"count\": \"7\", \"created_at\": 1704196800 }\n    ],\n    \"b\": \"not-an-array\"\n  }\n}\n";

/** 对应 fixtures/chapter-images.auth-required.json */
export const CHAPTER_IMAGES_AUTH_REQUIRED: string = "{\"status\":\"login\"}\n";

/** 对应 fixtures/chapter-images.derived.json */
export const CHAPTER_IMAGES_DERIVED: string = "{\n  \"chapter\": {\n    \"this\": { \"count\": 3 },\n    \"next\": { \"count\": 5 },\n    \"last\": { \"count\": 2 }\n  },\n  \"data\": { \"count\": 9 }\n}\n";

/** 对应 fixtures/chapter-images.zero-cid.derived.json */
export const CHAPTER_IMAGES_ZERO_CID_DERIVED: string = "{\n  \"chapter\": {\n    \"this\": { \"count\": 2, \"name\": \"單本\" },\n    \"next\": { \"count\": 0 },\n    \"last\": { \"count\": 0 }\n  },\n  \"data\": {\n    \"count\": 9,\n    \"name\": \"單本作品\",\n    \"author\": \"範例作者\"\n  }\n}\n";

/** 对应 fixtures/favorite-classes.success.derived.json */
export const FAVORITE_CLASSES_SUCCESS_DERIVED: string = "{\n  \"status\": \"ok\",\n  \"data\": [\n    { \"id\": 3, \"name\": \"默認收藏\" },\n    { \"id\": \"5\", \"name\": \"特別喜歡\" }\n  ]\n}\n";

/** 对应 fixtures/home.no-stream.derived.json */
export const HOME_NO_STREAM_DERIVED: string = "{\n  \"status\": \"ok\"\n}\n";

/** 对应 fixtures/home.success.derived.json */
export const HOME_SUCCESS_DERIVED: string = "{\n  \"status\": \"ok\",\n  \"bulletin\": {\n    \"text\": \"系統維護公告（範例，非真實資料）\",\n    \"show\": true\n  },\n  \"favDay\": [\n    {\n      \"Bid\": 900401,\n      \"Bookname\": \"日收藏範例 A\",\n      \"Author\": \"範例作者 A\",\n      \"Description\": \"用於首頁聚合解析測試的範例條目（非真實資料）\",\n      \"Ptag\": \"標籤甲 標籤乙\",\n      \"Otag\": \"其他標籤\",\n      \"Views\": 100,\n      \"Favorites\": 50,\n      \"RatingSUM\": 86,\n      \"Mode\": 1,\n      \"Status\": 1,\n      \"publish_year\": \"2023\",\n      \"Len\": 20\n    },\n    {\n      \"Bid\": \"900406\",\n      \"Bookname\": \"日收藏範例 F\",\n      \"Author\": \"範例作者 F\"\n    }\n  ],\n  \"readDay\": [\n    {\n      \"Bid\": \"900402\",\n      \"Bookname\": \"日閱讀範例 B\",\n      \"Author\": \"範例作者 B\"\n    }\n  ],\n  \"fs\": [\n    {\n      \"Bid\": 900403,\n      \"Bookname\": \"推薦位範例 C\",\n      \"Author\": \"範例作者 C\",\n      \"Mode\": 1,\n      \"Status\": 0\n    }\n  ],\n  \"proportion\": [\n    {\n      \"Bid\": 900404,\n      \"Bookname\": \"高質量範例 D\"\n    },\n    {\n      \"Bid\": \"900405\",\n      \"Bookname\": \"高質量範例 E\",\n      \"Author\": \"範例作者 E\"\n    }\n  ],\n  \"tags\": \"冒險 奇幻 戀愛\"\n}\n";

/** 对应 fixtures/home.with-stream.derived.json */
export const HOME_WITH_STREAM_DERIVED: string = "{\n  \"status\": \"ok\",\n  \"stream\": [\n    {\n      \"sid\": 501,\n      \"name\": \"動畫範例 A\",\n      \"des\": \"動畫劇情簡介（範例，非真實資料）\",\n      \"tags\": \"動作,冒險\",\n      \"pages\": \"12\",\n      \"type\": 1,\n      \"count\": 12,\n      \"time\": 1735689600,\n      \"up_time\": 1735689600,\n      \"f\": true,\n      \"views\": 999,\n      \"favorites\": 88\n    },\n    {\n      \"sid\": \"502\",\n      \"name\": \"動畫範例 B\"\n    }\n  ],\n  \"tags\": [\"動畫\", \"熱血\"]\n}\n";

/** 对应 fixtures/login.empty-form.json */
export const LOGIN_EMPTY_FORM: string = "{\"status\":\"error\"}\n";

/** 对应 fixtures/login.invalid-credentials.json */
export const LOGIN_INVALID_CREDENTIALS: string = "{\"status\":\"error\"}";

/** 对应 fixtures/logout.anon.json */
export const LOGOUT_ANON: string = "{\"status\":\"login\"}\n";

/** 对应 fixtures/logout.success.derived.json */
export const LOGOUT_SUCCESS_DERIVED: string = "{\n  \"status\": \"logout\"\n}\n";

/** 对应 fixtures/msg-count.success.derived.json */
export const MSG_COUNT_SUCCESS_DERIVED: string = "{\n  \"status\": \"ok\",\n  \"count\": {\n    \"all\": 5,\n    \"sys_msg\": 1,\n    \"community_reply\": 2,\n    \"comment_reply\": 2\n  }\n}\n";

/** 对应 fixtures/msg-list.reply.derived.json */
export const MSG_LIST_REPLY_DERIVED: string = "{\n  \"status\": \"ok\",\n  \"reply\": {\n    \"comment\": [\n      {\n        \"id\": 7001,\n        \"content\": \"回覆內容一（範例，非真實資料）\",\n        \"time\": 1735689600,\n        \"bid\": 900201,\n        \"cover\": \"m/900201.webp\"\n      },\n      {\n        \"id\": \"7002\",\n        \"content\": \"回覆內容二\",\n        \"time\": 1735689700,\n        \"bid\": \"900202\"\n      }\n    ]\n  },\n  \"over\": true\n}\n";

/** 对应 fixtures/search.auth-required.json */
export const SEARCH_AUTH_REQUIRED: string = "{\"status\":\"login\"}";

/** 对应 fixtures/search.empty.derived.json */
export const SEARCH_EMPTY_DERIVED: string = "{\n  \"data\": [],\n  \"count\": 0\n}\n";

/** 对应 fixtures/search.success.derived.json */
export const SEARCH_SUCCESS_DERIVED: string = "{\n  \"data\": [\n    {\n      \"id\": 900101,\n      \"name\": \"範例作品 A\",\n      \"author\": \"範例作者 A\",\n      \"description\": \"用於解析測試的範例條目（非真實資料）\",\n      \"tags\": [\"標籤甲\", \"標籤乙\"],\n      \"pname\": [\"第 1 話\"],\n      \"otag\": [\"其他標籤\"],\n      \"views\": 12345,\n      \"favorites\": 678,\n      \"rating_sum\": 4321,\n      \"adult\": false,\n      \"mode\": \"book\",\n      \"status\": \"ongoing\",\n      \"publish_year\": 2024,\n      \"source\": \"book\"\n    },\n    {\n      \"id\": \"900102\",\n      \"name\": \"範例作品 B\",\n      \"author\": \"範例作者 B\",\n      \"description\": \"\",\n      \"tags\": [],\n      \"pname\": [],\n      \"otag\": [],\n      \"views\": 0,\n      \"favorites\": 0,\n      \"rating_sum\": 0,\n      \"adult\": false,\n      \"mode\": \"stream\",\n      \"status\": \"finished\",\n      \"publish_year\": \"2023\",\n      \"source\": \"stream\"\n    },\n    {\n      \"id\": 900103,\n      \"name\": \"最小欄位作品\"\n    }\n  ],\n  \"count\": 42\n}\n";

/** 对应 fixtures/userinfo.anon.json */
export const USERINFO_ANON: string = "{\"status\":\"login\"}\n";

/** 对应 fixtures/userinfo.success.derived.json */
export const USERINFO_SUCCESS_DERIVED: string = "{\n  \"status\": \"ok\",\n  \"userinfo\": {\n    \"Uid\": 900001,\n    \"Name\": \"範例使用者\",\n    \"Username\": \"sample_user\",\n    \"Avatar\": \"avatar/900001.webp\",\n    \"Bg\": \"bg/900001.webp\",\n    \"Time\": 1735689600,\n    \"CommentLen\": 12,\n    \"Integral\": 8888\n  }\n}\n";
