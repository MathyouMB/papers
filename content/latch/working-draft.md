# LATCH: A Durable Protocol for Real-Time Event Delivery

<div style="margin-top: -2.0rem">
<img src="./images/logo-with-title.png" alt="LATCH Logo" width="300px" />
</div>

_By: [Matthew MacRae-Bovell](https://matthewmacraebovell.com/)_

_Last Updated_: July 22, 2025

**Abstract**

LATCH is a protocol for delivering events between systems using a durable, pull-based model that aims to address the integration complexity commonly associated with webhooks. Instead of sending events over HTTP as transient push-based webhooks, LATCH specifies that publishers write events to per-consumer inboxes. Consumers then fetch events from these inboxes using a cursor-based API. This approach significantly reduces integration time and complexity, especially in scenarios where reliable event delivery is critical to the consumer by eliminating the need to implement significant custom infrastructure. This document specifies the LATCH protocol and its reference API.

## Introduction

Webhooks are a widely adopted mechanism for delivering notifications between systems. In most webhook models, a producer issues an HTTP request to a consumer-provided endpoint whenever a relevant event occurs. This approach is easy to implement and works well for simple use cases, such as posting a message to a Slack channel when a deployment completes or being alerted when a new feedback submission is received.

However, for production-grade integrations, particularly those involving mission-critical workflows, this model introduces significant operational challenges. Ensuring reliable delivery of webhook events typically requires consumers to implement and maintain a considerable amount of infrastructure:

- A publicly accessible web server or endpoint
- Request validation and schema handling
- Idempotency mechanisms to avoid duplicate processing
- Queues and buffers to decouple receipt from downstream handling
- Dead-letter handling for persistent failures
- Persistent storage for tracking delivery attempts
- Retry logic with exponential backoff and monitoring

This overhead is often duplicated across consumers, increasing complexity and introducing opportunities for failure. In practice, it limits integration success: smaller partners may be unable to support the necessary infrastructure, while others deploy brittle systems that silently drop data under load or fail to recover from transient errors.

For the publisher, this results in fewer successful integrations, increased support costs, slower partner onboarding, and potentially negatively impacted trust with their own customers. Lowering the operational burden on consumers has direct benefits: broader adoption, faster time-to-value for partners, and a more robust ecosystem of integrations.

This paper introduces LATCH (Log-based Asynchronous Transport for CHange events), a pull-based protocol that rethinks the delivery model for webhook-like integrations. Rather than pushing events to consumer endpoints, producers append them to per-consumer inboxes. Consumers retrieve these events using a cursor-based polling interface. This model enables durable delivery, reduces complexity for consumers, and improves debuggability and fault tolerance.

In this paper we will describe the LATCH protocol, its architecture, and how it addresses the limitations of traditional webhook systems.

## Background

The rise of APIs and event-driven systems over the last two decades has made event notification a critical part of modern system architecture. Webhooks emerged as a popular solution in the early 2010s, largely because of their simplicity: a producer issues an HTTP POST to a consumer-provided URL when something changes. This minimal, push-based pattern required no polling, no shared schema, and no persistent connection, making it easy to adopt and implement across diverse platforms.

### Webhooks Lack Standardization

Despite their ubiquity, webhook systems lack a standardized specification. Unlike protocols such as OAuth 2.0, OpenID Connect, or even RSS, webhooks have no formal schema, handshake, retry contract, or discovery mechanism. This absence of standardization has led to a wide spectrum of implementations, each with their own delivery guarantees, payload formats, and failure semantics.

In practice, most webhook providers do not guarantee delivery, ordering, or idempotency. Instead, they rely on best-effort push semantics over HTTP and offload the responsibility for correctness to the consumer. Providing guaranteed one time delivery, ordering, and idempotency is difficult for the publisher because it requires them to implement complex retry logic, deduplication, and failure recovery given the consumer may not be reachable or may fail to process the event correctly.

To achieve production-grade reliability, consumers are typically required to implement retry handling with exponential backoff and timeout tolerance, deduplication logic based on event identifiers or hashes, failure recovery workflows such as dead-letter queues or manual replays, and security enforcement mechanisms like HMAC validation and replay protection. These concerns must be addressed in nearly every integration, yet each team reinvents the same scaffolding independently. The lack of shared conventions results in increased integration costs and a higher likelihood of subtle delivery bugs.

In addition to protocol inconsistencies, webhook payload design varies significantly across providers. Some systems deliver extremely sparse messages, often containing nothing more than a resource identifier and an event type. This minimalist approach, exemplified by some Stripe and Square events, forces consumers to perform follow-up API calls to retrieve full context. While this reduces publisher-side bandwidth, it increases overall system latency, introduces coupling between the webhook and the source API, and creates additional failure surfaces.

Conversely, some providers attempt to include the full context of the event inline. GitHub, for example, often delivers webhook payloads that contain the entire resource tree associated with the change. While this improves autonomy and reduces the need for follow-up calls, it significantly increases payload size. Large, verbose payloads result in greater bandwidth consumption, higher delivery latency, and increased risk of consumer-side timeouts.

Neither sparse nor bloated payloads represents a well-optimized delivery model. And without formal guidance, developers are left to navigate this space through trial and error.

These limitations make clear that while webhook delivery is widely adopted, it is not mature. The lack of standardization, weak delivery guarantees, inconsistent payload strategies, and poor observability contribute to a fragile and fragmented ecosystem.

### Webhook Use Cases

Current webhook infrastructure treats all deliveries as transient and fire-and-forget. This model imposes a uniform fragility across use cases, requiring consumers to compensate for missed messages, implement idempotency, and manage delivery durability independently.

Although a good percentage of webhook use cases are simple non-critical notifications, there is a growing trend towards using webhooks as entry points for critical business logic and data synchronization. These use cases require stronger delivery guarantees, ordering, and replayability than traditional webhook systems provide today.

Even lightweight non-critical notifications, such as triggering visual indicators or posting status messages to team communication channels, still suffer from invisible failure modes. Events may be silently dropped due to transient downtime, DNS misconfiguration, or upstream throttling, and the lack of delivery introspection makes root cause analysis exceedingly difficult. The operational simplicity of these use cases does not negate their brittleness.

The limitations of push-based webhooks become more severe in the context of business-critical workflows. Increasingly, webhook deliveries serve as authoritative triggers for operations such as provisioning access, initiating fulfillment after a successful transaction, or launching automated deployment processes. Webhooks are also widely used for data synchronization across service boundaries, where consistency and ordering are paramount. Systems may rely on webhooks to mirror user profile data between services, update external analytics pipelines, or keep third-party integrations in sync with the source of truth. These synchronization patterns are extremely sensitive to delivery guarantees: a single missing or duplicated event can result in data corruption, stale state, or downstream inconsistency. Traditional webhooks are ill-equipped to handle such requirements, as push delivery offers no inherent guarantees around ordering, visibility, or recoverability. Consumers often resort to full resynchronization or redundant polling of upstream APIs to compensate for webhook unreliability.

### The Need for a New Model

The limitations of webhook systems highlight the need for a more robust, standardized approach to event delivery. A protocol that provides durable, reliable, and observable event transport can significantly reduce the operational burden on consumers while improving integration success rates.

By shifting responsibility for delivery guarantees to the producer, such a model allows consumers to interact with event streams more safely and predictably. It simplifies integration, reduces the likelihood of silent failure, and makes systems easier to debug and operate. Crucially, relocating delivery infrastructure to the platform itself leads to more reliable integrations, benefiting not only developers but also the platform provider. When integration success is a first-class concern of the platform, the support burden shifts accordingly. Fewer developers encounter delivery issues, fewer bugs are caused by missed or duplicated events, and fewer support cycles are spent troubleshooting fragile, consumer-managed webhook implementations. This improves the overall developer experience while lowering the cost of maintaining a partner ecosystem.

## Protocol Specification

This section defines the LATCH protocol, including its core concepts, required endpoints, and message semantics. LATCH specifies how producers write events to consumer-specific inboxes, and how consumers poll and acknowledge those events using a cursor-based API.

### Terminology

- **Producer**: The system or service that generates events.
- **Consumer**: The system or client that retrieves events using the LATCH protocol.
- **Inbox**: A durable log of events scoped to a specific consumer, maintained by the producer.
- **Event**: A discrete, immutable data record representing a change in the producer’s system.
- **Cursor**: An opaque identifier marking a consumer’s read position in their inbox.
- **Acknowledgment**: A consumer signal that all events up to a specific cursor have been successfully processed.

### Event Delivery Model

In LATCH, producers do not push events directly to consumer endpoints. Instead, they append events to a per-consumer inbox, which acts as a durable, append-only log. Consumers retrieve events by explicitly requesting new messages, either periodically (polling), during startup, or in response to lightweight "notify" hints delivered via webhook. This makes LATCH a pull-based protocol that supports event-driven retrieval without requiring long-lived HTTP infrastructure on the consumer side.

This model enables:

- **Durable delivery**: Events are not lost due to transient network failures or consumer downtime.
- **Backpressure tolerance**: Consumers request messages at their own pace.
- **Resumability**: Consumers can resume from the last known good cursor after failure.
- **Simplified integration**: Consumers do not need to implement retry queues or handle webhook-specific delivery semantics.

### Event Ordering

Events in an inbox are returned in the order they were written. This ordering must be stable and deterministic per inbox. Reordering, duplication, or omission of events is not permitted unless explicitly allowed by the configuration.

### Cursor Semantics

A cursor is an opaque identifier that represents a position in the inbox. Producers must treat cursors as immutable and unique per event. Consumers must not guess or construct cursors. They should only use those returned by the server.

### Protocol Flow

```
     +------------+                               +---------------+
     |            |--(A)-- Fetch Events --------->|               |
     |  Consumer  |                               |    Producer   |
     |            |<-(B)-- List of Events --------|               |
     |            |                               +---------------+
     |            |
     |            |--(C)-- Acknowledge Cursor --->|               |
     |            |                               |               |
     |            |<-(D)---- 200 OK --------------|               |
     +------------+                               +---------------+
```

**Figure 1: Abstract LATCH Protocol Flow**

- **(A)** The consumer requests events from its inbox, either during boot, periodically, or after receiving a notify hint.
- **(B)** The producer returns a list of events starting after the provided cursor.
- **(C)** After processing, the consumer optionally acknowledges the last successfully handled event.
- **(D)** The producer updates the cursor or retention metadata and returns a success response.

### HTTP Endpoints

All LATCH implementations must expose the following endpoints:

#### Producer Endpoints

The producer must implement the following endpoints to support the LATCH protocol:

##### GET /inboxes/{consumer_id}/events?after={cursor}

Retrieves a list of events after the given cursor (or from the beginning if omitted).

Producers SHOULD implement rate limiting on this endpoint to prevent excessive polling. Consumers are encouraged to adopt a hybrid model, requesting events either on boot, on a fixed schedule, or in response to `/inbox-status` notifications, rather than continuously polling in tight loops. This reduces unnecessary load and latency while preserving the benefits of on-demand delivery.

**Query Parameters:**

- `after` (optional): The ID of the last seen event. If omitted, returns events from the beginning of the inbox.
- `limit` (optional): The maximum number of events to return. If omitted, a default limit should be applied.

**Request Example:**

```http
GET /inboxes/example-consumer-id/events?after=event_1024
```

**Response Example:**

```json
{
  "events": [
    { "id": "event_1025", "type": "user.created", "payload": { ... } },
    { "id": "event_1026", "type": "invoice.paid",  "payload": { ... } }
  ],
  "next_cursor": "event_1026"
}
```

If no events are returned, `next_cursor` should equal the after cursor (or be null if the inbox is empty).

The consumer should use `next_cursor` in the next request to resume polling.

Cursor values are opaque and must not be constructed or modified by clients.

##### POST /inboxes/{consumer_id}/acknowledge

Acknowledges the successful processing of events up to a specific cursor.

**Request Body:**

```json
{
  "cursor": "event_1024"
}
```

**Response Example:**

```json
{
  "status": "ok"
}
```

If a consumer crashes, they can simply start again from their last seen event. No missed data. No retries. No dropped webhooks.

#### Consumer Endpoints

The consumer must implement the following endpoints to support the LATCH protocol:

##### POST /inbox-status

While LATCH is fundamentally a pull-based protocol, producers MAY optionally send inbox status notifications to registered consumer endpoints when new events are available or the consumer appears idle. These notifications are not required for correctness, but serve as a hint to reduce polling latency and improve responsiveness.

These messages resemble traditional webhooks in format but are advisory only, no delivery guarantees or retries are required, and they carry no event data. They exist purely as optimization hints and must not be relied upon for correctness.

```http
POST /inbox-status
```

```json
{
  "consumer_id": "example-consumer-id",
  "status": "new_events_available",
  "inbox": {
    "unread_count": 3,
    "oldest_event_id": "event_2048",
    "latest_event_id": "event_2050"
  },
  "timestamp": "2025-07-22T18:45:00Z"
}
```

### Authentication and Security

LATCH does not prescribe a specific authentication mechanism, but all requests to inbox endpoints should be authenticated.

### Versioning

LATCH does not mandate a specific versioning scheme, but producers and consumers should implement versioning strategies to ensure backward compatibility.

## Discussion

The LATCH protocol represents a shift in how event-driven systems communicate, particularly when delivery guarantees and integration simplicity are paramount. While it builds upon ideas seen in log-based systems like Kafka and pull-based feeds like RSS, its explicit per-consumer delivery semantics and protocol-level cursor tracking distinguish it as a robust alternative to traditional webhooks.

### Benefits

#### Durability and Reliability

LATCH guarantees that events remain available to the consumer until explicitly acknowledged. This eliminates a common class of silent failures in webhook-based systems, where network partitions, DNS failures, or misconfigured endpoints can result in data loss with no opportunity for recovery. Because events are durably stored by the producer, reliability no longer depends on the transient success of an HTTP request.

#### Consumer Simplicity

By shifting delivery responsibility to the producer, LATCH minimizes infrastructure requirements for the consumer. Consumers no longer need to manage background retry queues or implement dead-letter handling. Instead, they issue authenticated fetch requests and track a cursor.

#### Observability and Debuggability

Traditional webhook delivery often lacks transparency. Developers struggle to determine whether a webhook fired, was received, or was dropped. LATCH improves this by making delivery state explicit. Because the producer owns the inbox and serves events via a cursor, it can expose metrics like event lag, unread count, or inbox backlog. This visibility enables better monitoring, debugging, and alerting throughout the integration lifecycle.

#### Better Developer Experience

Integration for consumers becomes a matter of fetching events and processing them in order. This not only reduces time-to-integration but improves correctness by removing ad hoc error handling and edge-case logic from consumer codebases.

Improved developer experience leads to faster onboarding, fewer bugs, and more successful integrations. By reducing the operational burden on consumers, LATCH enables the consumer to focus on building value rather than maintaining complex delivery infrastructure.

### Drawbacks and Limitations

The simplicity gained by the consumer is offset by complexity added to the producer. LATCH requires producers to implement durable storage, per-consumer inboxes, cursor tracking, and endpoint authentication. These concerns are nontrivial, especially in high-volume, multi-tenant systems. While tooling and infrastructure can mitigate this, producers must be prepared to invest in delivery infrastructure as a first-class responsibility.

#### Producer Complexity

The simplicity gained by the consumer is offset by complexity added to the producer. LATCH requires producers to implement durable storage, per-consumer inboxes, cursor tracking, and endpoint authentication. These concerns are nontrivial, especially in high-volume, multi-tenant systems. While tooling and infrastructure can mitigate this, producers must be prepared to invest in delivery infrastructure as a first-class responsibility.

#### Polling Latency

LATCH trades immediacy for control. In push-based systems, the producer initiates delivery as soon as an event occurs. In LATCH, the consumer dictates when to fetch, which introduces a variable delay between event emission and processing. This can be mitigated with short polling intervals or proactive notify hints, but cannot fully match the low-latency delivery of webhooks in ideal network conditions.

#### Storage and Retention Costs

LATCH requires producers to retain events until they are explicitly acknowledged. This increases storage usage compared to fire-and-forget models. Retention policies, tiered storage, or archiving can alleviate the burden, but high-throughput systems must carefully monitor disk usage and pruning policies. Cost becomes a shared trade-off in exchange for stronger delivery semantics.

#### Lack of Real-Time Push

LATCH is a pull-based protocol. While optional notify hints can bridge the gap and reduce latency, they are not guaranteed to arrive or retry. Consumers requiring real-time responsiveness (e.g., for live UI updates) may need to supplement LATCH with push-based overlays or websocket channels. For many back-office and system-to-system use cases, however, near-real-time delivery is sufficient.

<!-- ### Delivery Models Compared

This section compares LATCH to existing event delivery mechanisms across multiple dimensions, with a focus on reliability, operational complexity, consumer experience, and architectural trade-offs. While LATCH rethinks the delivery model, it is not a universal replacement for push-based systems. Understanding its strengths and limitations is essential for determining its applicability in real-world environments. -->

### LATCH vs. Webhooks

LATCH offers significant improvements in reliability, observability, and consumer simplicity by shifting responsibility for event delivery from the consumer to the producer. However, this shift introduces its own trade-offs.

LATCH also increases complexity for the producer. It must implement durable inboxes, serve paginated event streams, and manage cursor tracking. In contrast, webhook delivery requires only a fire-and-forget HTTP request. For small systems or trusted internal consumers, the additional overhead of LATCH may not be justified.

The most immediate cost is storage. Unlike webhooks, which transmit ephemeral notifications and discard them after delivery (successful or not), LATCH requires the producer to persist events until they are explicitly acknowledged. This increases infrastructure demands, particularly for high-throughput systems or when consumers are slow to process events. Producers must account for disk usage, retention policies, and pruning strategies to ensure scalability over time.

Additionally, latency characteristics differ. Webhooks can deliver events as soon as they are emitted, resulting in near-instantaneous delivery, assuming the consumer is online and reachable. LATCH relies on polling, which introduces a delay between when an event is written and when it is observed by the consumer. While this delay can be minimized with short polling intervals or long-polling techniques, it is unlikely to match the immediacy of push-based systems under ideal conditions.

LATCH was designed to address many of the reliability and integration challenges of traditional webhooks. However, like any architectural shift, adopting LATCH introduces its own trade-offs. This section compares the two models across several dimensions.

| Dimension               | Webhooks                                          | LATCH                                            |
| ----------------------- | ------------------------------------------------- | ------------------------------------------------ |
| **Delivery Model**      | Push-based via HTTP                               | Pull-based via cursor-based HTTP polling         |
| **Consumer Simplicity** | Requires HTTP server, retries, deduping, etc.     | Minimal client logic; polling loop with cursor   |
| **Durability**          | Requires queues or retries to avoid data loss     | Events are durably persisted until acknowledged  |
| **Error Recovery**      | Must reimplement retry + DLQ semantics            | Consumers re-poll from known cursor              |
| **Delivery Latency**    | Near-instantaneous (when working)                 | Polling interval determines freshness            |
| **Producer Complexity** | Simple, fire and forget                           | Must persist and serve event logs                |
| **Consumer Visibility** | Difficult to debug (e.g. silent failures)         | Easy to observe consumer lag and inbox contents  |
| **Integration Cost**    | High, especially for smaller or third-party teams | Low, can integrate with a simple loop and cursor |

<!-- #### LATCH vs. Event Destinations

(TODO: I'll add a comparison with Event Destinations in the future)

#### LATCH vs WebSub

(TODO: I'll add a comparison with WebSub in the future) -->

### Recommended Use Cases

LATCH is particularly well-suited for systems where durability, introspectability, and integration simplicity take precedence over raw delivery speed. These characteristics make it an ideal fit for a wide range of modern integration scenarios that struggle with the limitations of traditional webhook infrastructure.

One of the most compelling applications for LATCH is in developer platforms that support a large and diverse ecosystem of third-party consumers. In such environments, expecting each integration to independently manage HTTP endpoints, request validation, retry logic, deduplication, and failure recovery creates substantial friction. These requirements often act as a barrier to entry, especially for smaller teams or external developers who lack the operational capacity to implement resilient infrastructure. As a result, platform providers face slower partner onboarding, inconsistent integration quality, and a growing support burden as developers encounter delivery issues or silent data loss.

By shifting responsibility for delivery durability to the platform, LATCH reduces this burden and centralizes control over delivery guarantees. This change significantly improves the reliability of integrations across the board. Developers are no longer required to reimplement foundational delivery mechanics, enabling them to focus on application logic rather than infrastructure concerns. For the platform, this translates to fewer failed integrations, reduced support load, and increased developer satisfaction. It also ensures that integration success is treated as a first-class concern of the platform, not an afterthought left to the consumer’s discretion or resources.

Importantly, while LATCH offers compelling advantages in these cases, it is not intended to replace internal messaging systems. For intra-organization communication, especially when low latency, high throughput, or complex routing is required, existing technologies like Apache Kafka, NATS, MQTT, or other message queues are better suited. These systems offer rich features for stream processing, topic-based routing, and backpressure handling, and are more appropriate for internal service meshes, microservice coordination, or real-time event streaming.

LATCH instead fills a gap between webhook simplicity and message queue robustness: it is ideal for external-facing APIs and partner integrations where the producer must offer reliable delivery, but the consumer cannot be expected to implement or operate a message broker.

LATCH is not a universal replacement for webhooks, but it is a significantly better default for systems that prioritize reliability, supportability, and developer experience. Its design simplifies integration, improves delivery guarantees, and creates stronger accountability at the platform layer, benefits that compound in environments where integration failure is costly and success is critical.

### Notify Hints vs. Long Polling

LATCH allows producers to send lightweight webhook-style notify hints to consumers when new events are available. While these advisory messages can improve responsiveness and reduce average polling delay, they come with meaningful limitations compared to long polling.

#### Limitations of Notify Webhooks

Notify hints resemble traditional webhooks in format, but they are not guaranteed to be delivered or retried. If the notification is dropped or results in a transient error (e.g., a 500 response), the consumer may miss the opportunity to poll promptly and will rely on its next scheduled polling interval. This introduces a potential latency gap unless fallback polling is in place.

Moreover, notify hints require consumers to expose a public HTTP endpoint. This reintroduces one of the infrastructure requirements that LATCH was designed to eliminate. It also subjects the consumer to ingress considerations, firewall configuration, and operational complexity that the pull-based model otherwise avoids.

Finally, even when delivered, webhook notifications offer no guarantees about timeliness. They may be deprioritized by the producer, delayed by queues, or throttled under load. As a result, the worst-case latency remains governed by the consumer’s polling interval.

#### Advantages of Long Polling

In contrast, long polling allows consumers to issue a fetch request that remains open until an event is available or a timeout occurs. This technique preserves LATCH’s outbound-only model, avoiding the need for the consumer to accept incoming requests.

Because the consumer is responsible for initiating the connection, long polling guarantees regular checks for new events, even if no notify hints are delivered. It also reduces tail latency: by holding the connection open, the producer can respond immediately when a new event is written, enabling near-real-time delivery without sacrificing reliability or simplicity.

#### Hybrid Strategy

LATCH supports a hybrid strategy that combines scheduled polling (or long polling) with optional notify hints. This pattern ensures baseline delivery guarantees through polling while opportunistically improving responsiveness when producers send hints about new data.

By treating notify hints as latency optimizers rather than delivery mechanisms, consumers can remain robust to network issues, misfires, or dropped webhooks, preserving the benefits of LATCH’s durability while avoiding unnecessary fragility.

### Migration Considerations

Adopting LATCH does not require an immediate replacement of existing webhook infrastructure. In fact, LATCH is designed to coexist with traditional webhooks, enabling a gradual migration strategy that minimizes disruption to existing consumers.

Producers MAY support both delivery models in parallel by introducing LATCH endpoints alongside existing webhook registration flows. For example, consumers could opt in to LATCH delivery by registering a polling consumer ID instead of a callback URL. Events can then be delivered to both the traditional webhook pipeline and the LATCH inbox for the same integration.

Over time, producers can deprecate webhook endpoints or offer incentives for consumers to transition, such as improved reliability, reduced delivery errors, or access to historical event replays only available via LATCH.

## Architecture and Implementation

The LATCH protocol is implementation-agnostic. It specifies the interaction model between producers and consumers but does not mandate any particular storage engine, messaging system, or deployment architecture. This separation of concerns allows LATCH to be adapted to a wide range of environments, from small-scale internal services to large-scale multi-tenant platforms.

This section describes the architectural patterns and trade-offs involved in implementing LATCH, with a focus on scalability, storage strategies, and delivery guarantees.

### Core Components

A minimal implementation of LATCH consists of the following:

- **Inbox Store:** A per-consumer append-only log that holds events in insertion order. Each inbox MUST preserve order and support cursor-based reads.

- **API Layer:** A stateless HTTP interface that exposes the required endpoints (`GET /events`, `POST /acknowledge`) and handles authentication, authorization, pagination, and rate limiting.

- **Event Writer:** The system component that writes events to the appropriate consumer inboxes as changes occur in the producer’s system.

- **Retention Policy:** Logic for determining how long to store unacknowledged events. Producers MAY retain all events indefinitely, expire old ones, or archive them externally.

- **Cursor Tracker:** A lightweight mechanism (e.g., a key-value store) to track the last acknowledged event ID per consumer, used for storage cleanup or analytics.

### Cost Analysis

At large scale, the cost of durable inbox storage becomes significant. Here we analyze storage costs assuming 10 billion events per day routed to partner apps.

**Assumptions:**

- 10 billion events/day, each **5 KB**
- All events are broadcast to 50,000 inboxes (i.e. full fan-out)
- Retention window: 3 days (rolling durability)
- Storage tier: AWS S3 Standard ($0.023/GB/month)
- Cursor tracking via DynamoDB ($0.25/GB/month)
- Optional cold archival to AWS Glacier ($0.004/GB/month)
- Per-day data volume: 10B events × 5 KB = **50 TB/day**
- 3-day retention (shared storage): 50 TB × 3 = **150 TB total**
- Metadata overhead: estimated at ~50% of content volume = **75 TB**

**Monthly Costs:**

| Component                      | Volume | Rate            | Monthly Cost              |
| ------------------------------ | ------ | --------------- | ------------------------- |
| **Event log (S3)**             | 150 TB | $0.023/GB       | **$3,450**                |
| **Metadata (EBS or S3)**       | 75 TB  | $0.023–$0.10/GB | **$1,725–$7,500**         |
| **Cursor tracking (DynamoDB)** | ~1 GB  | $0.25/GB        | **$0.25**                 |
| **Cold archive (10%)**         | 15 TB  | $0.004/GB       | **$60**                   |
| **Total**                      | —      | —               | **~$5,200–$11,000/month** |

Even under a high-throughput of **10 billion events/day** with **5 KB payloads**, a well-architected LATCH system using **shared storage and indexed inboxes** achieves total monthly costs of **~$5,000–$11,000**. This centralized infrastructure delivers durable, replayable, and observable delivery to 50,000 consumers—at a fraction of the cost incurred by individual webhook implementations failing independently.

### Inbox Pruning and Retention Policies

LATCH requires producers to retain events in each inbox until they are acknowledged by the consumer. This guarantees that events are durably available in the face of consumer failures, network partitions, or slow polling intervals. However, indefinite retention is not feasible or desirable, particularly in high-throughput systems or when working with constrained storage.

Producers MUST implement a retention policy for pruning old or unacknowledged events. The policy should define how long events are kept in an inbox and under what conditions they may be deleted. Implementations MAY support any of the following strategies:

- **Time-based expiration**: Retain events for a fixed duration (e.g., 7 days) after insertion, regardless of acknowledgment status.
- **Size-based limits**: Cap the number of retained events per inbox or the total disk usage per consumer.
- **Acknowledgment-driven pruning**: Immediately remove all events older than the most recent acknowledged cursor.
- **Tiered archiving**: Move old events to cold storage (e.g., S3 or Glacier) after a period, allowing rehydration if necessary.

Each implementation SHOULD clearly document its retention behavior and any guarantees it makes to consumers. For example, a platform may promise that “events will be retained for at least 3 days or until acknowledged, whichever is longer.” Consumers should be designed to poll and acknowledge frequently enough to avoid losing access to unacknowledged events.

If a consumer attempts to resume from a cursor that no longer exists due to pruning, the server MUST return an error (e.g., `410 Gone`) indicating that the cursor is no longer valid.

Producers MAY expose metadata such as retention windows, cursor expiration hints, or inbox backlog size to help consumers adapt their polling behavior dynamically.

### Scalability

LATCH is horizontally scalable by design. With each inbox is scoped to a specific consumer, reads can be independently sharded across nodes using the `consumer_id`, and writes can be isolated to dedicated partitions per inbox. Cursor tracking is entirely local to each consumer and requires no global coordination.

### Inbox Lag Management

While LATCH enables consumer-paced delivery, this flexibility introduces the risk of consumers falling significantly behind, creating unbounded backlog growth, delayed processing, and potential retention violations. To maintain system health and fairness in multi-tenant environments, producers SHOULD implement policies for detecting and managing inbox lag.

#### Lag Detection

Lag can be measured using one or more of the following metrics:

- **Time lag**: The duration between the oldest unacknowledged event and the current time.
- **Message lag**: The number of events that remain unacknowledged.
- **Storage lag**: The total disk space consumed by a given inbox.

Producers MAY expose these metrics per consumer to observability systems, or return them as part of `/inboxes/{consumer_id}/events` or `/inbox-status` responses to aid client-side tuning.

#### Warning Thresholds

Producers SHOULD define thresholds that trigger soft alerts or logs when lag metrics exceed predefined limits. For example, they may warn if a consumer has not acknowledged any events in 24 hours, if an inbox contains more than 10,000 unacknowledged events, or if disk usage for a single inbox exceeds 500 MB. These warnings help operators detect unresponsive or unhealthy consumers before they impact overall system performance or trigger retention enforcement mechanisms.

#### Eviction and Retention Enforcement

If a consumer persistently lags beyond acceptable thresholds, producers MAY take corrective action to preserve system stability and prevent unbounded resource usage. This can include selectively evicting events or enforcing retention boundaries. In such cases, producers may implement soft eviction, where events that exceed the configured retention window are pruned even if unacknowledged. If a consumer attempts to resume from a cursor that references evicted data, the server MUST return a 410 Gone response to indicate that the cursor is no longer valid. Producers SHOULD clearly document these behaviors and provide mechanisms to help consumers recover from eviction scenarios, such as cursor resets, full resynchronization options, or dedicated API endpoints for reinitializing inbox state. These recovery pathways are critical for minimizing disruption and ensuring that lagging consumers can safely resume processing without risking data inconsistency.

#### Consumer Best Practices

To minimize inbox lag and avoid data loss, consumers SHOULD acknowledge processed events as early as safely possible and monitor unread event count and age (if exposed) to detect falling behind.

Producers MAY expose advisory metadata in event responses, such as:

```json
"meta": {
  "inbox_size": 1021,
  "oldest_event_age": "2h35m",
  "retention_window": "72h"
}

```

This allows consumers to adapt polling intervals, throttle event processing, or trigger operator alerts as needed.

<!-- ### Reference Implementation

(TODO: I'll add a reference implementation in the future) -->

## Acknowledgments

LATCH was inspired by challenges faced in building developer experiences with webhook-based integrations during my time on the [Shopify](https://www.shopify.com/) [Flow](https://www.shopify.com/flow) Platform Team and [Jobber](https://www.jobber.com/) [Platform Experience](https://developer.getjobber.com/landing) Team.
