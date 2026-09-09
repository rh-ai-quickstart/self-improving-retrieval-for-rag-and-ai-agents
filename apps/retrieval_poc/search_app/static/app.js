const form = document.querySelector("#search-form");
const queryInput = document.querySelector("#query");
const topKInput = document.querySelector("#top-k");
const status = document.querySelector("#status");
const results = document.querySelector("#results");
const rawPanel = document.querySelector("#raw-panel");
const rawJson = document.querySelector("#raw-json");
const submit = form.querySelector("button");

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const query = queryInput.value.trim();
  if (!query) return;

  submit.disabled = true;
  status.textContent = "Searching…";
  results.replaceChildren();
  rawPanel.hidden = true;

  try {
    const response = await fetch("/search", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query, top_k: Number(topKInput.value) }),
    });
    const body = await response.json();
    if (!response.ok) throw new Error(body.detail || `Request failed (${response.status})`);

    status.textContent = `${body.results.length} results · ${body.elapsed_ms} ms · ${body.model_id}`;
    body.results.forEach((item) => results.appendChild(resultCard(item)));
    rawJson.textContent = JSON.stringify(body, null, 2);
    rawPanel.hidden = false;
  } catch (error) {
    status.textContent = "Search failed";
    const message = document.createElement("div");
    message.className = "error";
    message.textContent = error.message;
    results.appendChild(message);
  } finally {
    submit.disabled = false;
  }
});

function resultCard(item) {
  const article = document.createElement("article");
  article.className = "result";

  const head = document.createElement("div");
  head.className = "result-head";
  const title = document.createElement("h2");
  title.textContent = `${item.rank}. ${item.title}`;
  const score = document.createElement("span");
  score.className = "score";
  score.textContent = item.score.toFixed(4);
  head.append(title, score);

  const snippet = document.createElement("p");
  snippet.className = "snippet";
  snippet.textContent = item.snippet;
  const meta = document.createElement("div");
  meta.className = "meta";
  meta.textContent = `${item.document_id} · chunk ${item.chunk_index}`;
  article.append(head, snippet, meta);
  return article;
}

