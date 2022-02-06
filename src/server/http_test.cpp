#include "server/http.h"

#include <gtest/gtest.h>

#include <QJsonArray>
#include <QJsonObject>

#include "index/index.h"
#include "index/multi_index.h"
#include "server/metrics.h"
#include "store/ram_directory.h"

using namespace Acoustid;
using namespace Acoustid::Server;

class HttpTest : public ::testing::Test {
 protected:
    void SetUp() override {
        dir = QSharedPointer<RAMDirectory>::create();
        indexes = QSharedPointer<MultiIndex>::create(dir);
        metrics = QSharedPointer<Metrics>::create();
        handler = QSharedPointer<HttpRequestHandler>::create(indexes, metrics);
    }

    void TearDown() override {
        indexes->close();
    }

    QSharedPointer<RAMDirectory> dir;
    QSharedPointer<MultiIndex> indexes;
    QSharedPointer<Metrics> metrics;
    QSharedPointer<HttpRequestHandler> handler;
};

TEST_F(HttpTest, TestReady) {
    auto request = HttpRequest(HTTP_GET, QUrl("/_health/ready"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "OK\n");
}

TEST_F(HttpTest, TestAlive) {
    auto request = HttpRequest(HTTP_GET, QUrl("/_health/alive"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "OK\n");
}

TEST_F(HttpTest, TestMetrics) {
    auto request = HttpRequest(HTTP_GET, QUrl("/_metrics"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.header("Content-Type").toStdString(), "text/plain; version=0.0.4");
}

TEST_F(HttpTest, TestHeadIndex) {
    indexes->createIndex("testidx");
    auto request = HttpRequest(HTTP_HEAD, QUrl("/testidx"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "{}");
}

TEST_F(HttpTest, TestHeadIndexNotFound) {
    auto request = HttpRequest(HTTP_HEAD, QUrl("/testidx"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_NOT_FOUND);
    ASSERT_EQ(response.body().toStdString(),
              "{\"error\":{\"description\":\"index does not exist\",\"type\":\"not_found\"},\"status\":404}");
}

TEST_F(HttpTest, TestGetIndex) {
    indexes->createIndex("testidx");
    auto request = HttpRequest(HTTP_GET, QUrl("/testidx"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "{\"revision\":1}");
}

TEST_F(HttpTest, TestGetIndexNotFound) {
    auto request = HttpRequest(HTTP_GET, QUrl("/testidx"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_NOT_FOUND);
    ASSERT_EQ(response.body().toStdString(),
              "{\"error\":{\"description\":\"index does not exist\",\"type\":\"not_found\"},\"status\":404}");
}

TEST_F(HttpTest, TestPutIndex) {
    auto request = HttpRequest(HTTP_PUT, QUrl("/testidx"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "{\"revision\":1}");
}

TEST_F(HttpTest, TestPutIndexAleadyExists) {
    indexes->createIndex("testidx");
    auto request = HttpRequest(HTTP_PUT, QUrl("/testidx"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "{\"revision\":1}");
}

TEST_F(HttpTest, TestHeadDocument) {
    indexes->createIndex("testidx");
    indexes->getIndex("testidx")->insertOrUpdateDocument(111, {1, 2, 3});

    auto request = HttpRequest(HTTP_HEAD, QUrl("/testidx/_doc/111"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "{\"id\":111}");
}

TEST_F(HttpTest, TestHeadDocumentNotFound) {
    indexes->createIndex("testidx");

    auto request = HttpRequest(HTTP_HEAD, QUrl("/testidx/_doc/111"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_NOT_FOUND);
    ASSERT_EQ(response.body().toStdString(),
              "{\"error\":{\"description\":\"document does not exist\",\"type\":\"not_found\"},\"status\":404}");
}

TEST_F(HttpTest, TestGetDocument) {
    indexes->createIndex("testidx");
    indexes->getIndex("testidx")->insertOrUpdateDocument(111, {1, 2, 3});

    auto request = HttpRequest(HTTP_GET, QUrl("/testidx/_doc/111"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "{\"id\":111}");
}

TEST_F(HttpTest, TestGetDocumentNotFound) {
    indexes->createIndex("testidx");

    auto request = HttpRequest(HTTP_GET, QUrl("/testidx/_doc/111"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_NOT_FOUND);
    ASSERT_EQ(response.body().toStdString(),
              "{\"error\":{\"description\":\"document does not exist\",\"type\":\"not_found\"},\"status\":404}");
}

TEST_F(HttpTest, TestPutDocumentStringTerms) {
    indexes->createIndex("testidx");

    auto request = HttpRequest(HTTP_PUT, QUrl("/testidx/_doc/111"));
    request.setBody(QJsonDocument(QJsonObject{{"terms", "1,2,3"}}));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "{}");

    ASSERT_TRUE(indexes->getIndex("testidx")->containsDocument(111));
}

TEST_F(HttpTest, TestPutDocumentArrayTerms) {
    indexes->createIndex("testidx");

    auto request = HttpRequest(HTTP_PUT, QUrl("/testidx/_doc/111"));
    request.setBody(QJsonDocument(QJsonObject{{"terms", QJsonArray{1, 2, 3}}}));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "{}");

    ASSERT_TRUE(indexes->getIndex("testidx")->containsDocument(111));
}

TEST_F(HttpTest, TestDeleteDocument) {
    indexes->createIndex("testidx");
    indexes->getIndex("testidx")->insertOrUpdateDocument(111, {1, 2, 3});

    auto request = HttpRequest(HTTP_DELETE, QUrl("/testidx/_doc/111"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "{}");

    ASSERT_FALSE(indexes->getIndex("testidx")->containsDocument(111));
}

TEST_F(HttpTest, TestSearch) {
    indexes->createIndex("testidx");
    indexes->getIndex("testidx")->insertOrUpdateDocument(111, {1, 2, 3});
    indexes->getIndex("testidx")->insertOrUpdateDocument(112, {3, 4, 5});

    auto request = HttpRequest(HTTP_GET, QUrl("/testidx/_search?query=1,2,3"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "{\"results\":[{\"id\":111,\"score\":3},{\"id\":112,\"score\":1}]}");
}

TEST_F(HttpTest, TestSearchLimit) {
    indexes->createIndex("testidx");
    indexes->getIndex("testidx")->insertOrUpdateDocument(111, {1, 2, 3});
    indexes->getIndex("testidx")->insertOrUpdateDocument(112, {3, 4, 5});

    auto request = HttpRequest(HTTP_GET, QUrl("/testidx/_search?query=1,2,3&limit=1"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "{\"results\":[{\"id\":111,\"score\":3}]}");
}

TEST_F(HttpTest, TestSearchNoResults) {
    indexes->createIndex("testidx");
    indexes->getIndex("testidx")->insertOrUpdateDocument(111, {1, 2, 3});
    indexes->getIndex("testidx")->insertOrUpdateDocument(112, {3, 4, 5});

    auto request = HttpRequest(HTTP_GET, QUrl("/testidx/_search?query=7,8,9&limit=1"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "{\"results\":[]}");
}

TEST_F(HttpTest, TestBulkArray) {
    indexes->createIndex("testidx");
    indexes->getIndex("testidx")->insertOrUpdateDocument(112, {31, 41, 51});
    indexes->getIndex("testidx")->insertOrUpdateDocument(113, {31, 41, 51});

    auto request = HttpRequest(HTTP_POST, QUrl("/testidx/_bulk"));
    request.setBody(QJsonDocument(QJsonArray{
        QJsonObject{{"upsert", QJsonObject{{"id", 111}, {"terms", QJsonArray{1, 2, 3}}}}},
        QJsonObject{{"upsert", QJsonObject{{"id", 112}, {"terms", QJsonArray{3, 4, 5}}}}},
        QJsonObject{{"delete", QJsonObject{{"id", 113}}}},
        QJsonObject{{"set", QJsonObject{{"name", "foo"}, {"value", "bar"}}}},
    }));

    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "{}");

    ASSERT_TRUE(indexes->getIndex("testidx")->containsDocument(111));
    ASSERT_TRUE(indexes->getIndex("testidx")->containsDocument(112));
    ASSERT_FALSE(indexes->getIndex("testidx")->containsDocument(113));
    ASSERT_EQ(indexes->getIndex("testidx")->getAttribute("foo").toStdString(), "bar");
}

TEST_F(HttpTest, TestBulkObject) {
    indexes->createIndex("testidx");
    indexes->getIndex("testidx")->insertOrUpdateDocument(112, {31, 41, 51});
    indexes->getIndex("testidx")->insertOrUpdateDocument(113, {31, 41, 51});

    auto request = HttpRequest(HTTP_POST, QUrl("/testidx/_bulk"));
    request.setBody(QJsonDocument(QJsonObject{
        {"operations", QJsonArray{
            QJsonObject{{"upsert", QJsonObject{{"id", 111}, {"terms", QJsonArray{1, 2, 3}}}}},
            QJsonObject{{"upsert", QJsonObject{{"id", 112}, {"terms", QJsonArray{3, 4, 5}}}}},
            QJsonObject{{"delete", QJsonObject{{"id", 113}}}},
            QJsonObject{{"set", QJsonObject{{"name", "foo"}, {"value", "bar"}}}},
        }},
    }));

    auto response = handler->router().handle(request);
    ASSERT_EQ(response.body().toStdString(), "{}");
    ASSERT_EQ(response.status(), HTTP_OK);

    ASSERT_TRUE(indexes->getIndex("testidx")->containsDocument(111));
    ASSERT_TRUE(indexes->getIndex("testidx")->containsDocument(112));
    ASSERT_FALSE(indexes->getIndex("testidx")->containsDocument(113));
    ASSERT_EQ(indexes->getIndex("testidx")->getAttribute("foo").toStdString(), "bar");
}

TEST_F(HttpTest, TestFlush) {
    indexes->createIndex("testidx");
    indexes->getIndex("testidx")->insertOrUpdateDocument(111, {1, 2, 3});
    indexes->getIndex("testidx")->insertOrUpdateDocument(112, {3, 4, 5});

    auto request = HttpRequest(HTTP_POST, QUrl("/testidx/_flush"));
    auto response = handler->router().handle(request);
    ASSERT_EQ(response.status(), HTTP_OK);
    ASSERT_EQ(response.body().toStdString(), "{}");
}
