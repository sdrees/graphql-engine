mod sql;
pub use sql::handle_sql_request;
mod graphql;
pub use graphql::{handle_explain_request, handle_request, handle_websocket_request};
mod jsonapi;
pub use jsonapi::create_json_api_router;

use axum::{
    extract::DefaultBodyLimit,
    response::Html,
    routing::{get, post},
    Router,
};
use base64::engine::Engine;
use std::hash;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;

use crate::{
    authentication_middleware, build_cors_layer, explain_request_tracing_middleware,
    graphql_request_tracing_middleware, plugins_middleware, sql_request_tracing_middleware,
    EngineState, StartupError,
};

use super::types::RequestType;

const MB: usize = 1_048_576;

pub fn get_base_routes(state: EngineState) -> Router {
    let graphql_ws_route = Router::new()
        .route("/graphql", get(handle_websocket_request))
        .layer(axum::middleware::from_fn(|request, next| {
            graphql_request_tracing_middleware(RequestType::WebSocket, request, next)
        }))
        // *PLEASE DO NOT ADD ANY MIDDLEWARE
        // BEFORE THE `graphql_request_tracing_middleware`*
        // Refer to it for more details.
        .layer(TraceLayer::new_for_http())
        .with_state(state.clone());

    let graphql_route = Router::new()
        .route("/graphql", post(handle_request))
        .layer(axum::middleware::from_fn_with_state(
            state.clone(),
            plugins_middleware,
        ))
        .layer(axum::middleware::from_fn(
            hasura_authn_core::resolve_session,
        ))
        .layer(axum::middleware::from_fn_with_state(
            state.clone(),
            authentication_middleware,
        ))
        .layer(axum::middleware::from_fn(|request, next| {
            graphql_request_tracing_middleware(RequestType::Http, request, next)
        }))
        // *PLEASE DO NOT ADD ANY MIDDLEWARE
        // BEFORE THE `graphql_request_tracing_middleware`*
        // Refer to it for more details.
        .layer(TraceLayer::new_for_http())
        .with_state(state.clone());

    let explain_route = Router::new()
        .route("/v1/explain", post(handle_explain_request))
        .layer(axum::middleware::from_fn(
            hasura_authn_core::resolve_session,
        ))
        .layer(axum::middleware::from_fn_with_state(
            state.clone(),
            authentication_middleware,
        ))
        .layer(axum::middleware::from_fn(
            explain_request_tracing_middleware,
        ))
        // *PLEASE DO NOT ADD ANY MIDDLEWARE
        // BEFORE THE `explain_request_tracing_middleware`*
        // Refer to it for more details.
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let health_route = Router::new().route("/health", get(handle_health));

    Router::new()
        // serve graphiql at root
        .route("/", get(graphiql))
        // The '/graphql' route
        .merge(graphql_route)
        // The '/graphql' route for websocket
        .merge(graphql_ws_route)
        // The '/v1/explain' route
        .merge(explain_route)
        // The '/health' route
        .merge(health_route)
        // Set request payload limit to 10 MB
        .layer(DefaultBodyLimit::max(10 * MB))
}

/// Serve the introspection metadata file and its hash at `/metadata` and `/metadata-hash` respectively.
/// This is a temporary workaround to enable the console to interact with an engine process running locally.
pub async fn get_metadata_routes(
    introspection_metadata_path: &PathBuf,
) -> Result<Router, StartupError> {
    let file_contents = tokio::fs::read_to_string(introspection_metadata_path)
        .await
        .map_err(|err| StartupError::ReadSchema(err.into()))?;
    let mut hasher = hash::DefaultHasher::new();
    file_contents.hash(&mut hasher);
    let hash = hasher.finish();
    let base64_hash = base64::engine::general_purpose::STANDARD.encode(hash.to_ne_bytes());
    let metadata_routes = Router::new()
        .route("/metadata", get(|| async { file_contents }))
        .route("/metadata-hash", get(|| async { base64_hash }));
    Ok(metadata_routes)
}

pub fn get_sql_route(state: EngineState) -> Router {
    Router::new()
        .route("/v1/sql", post(handle_sql_request))
        .layer(axum::middleware::from_fn(
            hasura_authn_core::resolve_session,
        ))
        .layer(axum::middleware::from_fn_with_state(
            state.clone(),
            authentication_middleware,
        ))
        .layer(axum::middleware::from_fn(sql_request_tracing_middleware))
        // *PLEASE DO NOT ADD ANY MIDDLEWARE
        // BEFORE THE `explain_request_tracing_middleware`*
        // Refer to it for more details.
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

pub fn get_jsonapi_route(state: EngineState) -> Router {
    create_json_api_router(state)
}

pub fn get_cors_layer(allow_origin: &[String]) -> CorsLayer {
    build_cors_layer(allow_origin)
}

/// Health check endpoint
async fn handle_health() -> reqwest::StatusCode {
    reqwest::StatusCode::OK
}

async fn graphiql() -> Html<&'static str> {
    Html(include_str!("index.html"))
}
