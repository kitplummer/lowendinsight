// Every helper below tolerates a missing element.
//
// They were written against the report page's markup, which has an
// analyze-button and an invalid-url span. The landing page's form has neither,
// so disable_button threw on null.classList -- and because
// validate_and_submit calls preventDefault first, the throw left the form
// never submitting. Clicking Analyze did nothing at all, with the reason
// visible only in the browser console.
//
// The missing ids are now in the template, so this is belt and braces: a page
// that omits an optional element should lose that element's behaviour, not its
// ability to submit.
function el(id){
    return document.getElementById(id);
}

// Set when the Try It allowance of fresh analyses is used up (#152), so the
// form does not also claim the URL was invalid.
var try_it_limited = false;

function enable_button(){
    var button = el("analyze-button");
    if (!button) return;
    button.classList.remove("is-loading");
    button.removeAttribute("disabled");
}

function disable_button(){
    var button = el("analyze-button");
    if (!button) return;
    button.classList.add("is-loading");
    button.setAttribute("disabled", true);
}

function get_encoded_url(){
    var input = el("input-url");
    return input ? encodeURIComponent(input.value) : "";
}

function display_error() {
    var button = el("analyze-button");
    if (button) {
        button.classList.remove("is-loading");
        button.removeAttribute("disabled");
    }

    var input = el("input-url");
    if (input) input.classList.add("error");

    var message = el("invalid-url");
    if (message) message.style.display = "block";
}

function remove_error(){
    var input = el("input-url");
    if (input) input.classList.remove("error");

    var message = el("invalid-url");
    if (message) message.style.display = "none";

    var button = el("analyze-button");
    if (button) {
        button.disabled = false;
        button.classList.remove("is-loading");
    }
}

async function validate_url(encoded_url){
    var is_valid_url = false;
    var is_valid_repo = false;

    await fetch(`/validate-url/url=${encoded_url}`)
        .then(validate => {
            is_valid_url = (validate.status == 200);
        }).catch(error => console.log(error))

    if(is_valid_url){
        await fetch(`/url=${encoded_url}`)
            .then(analyze => {
                is_valid_repo = (analyze.status == 200);
                // The per-address allowance of fresh analyses is used up. Saying
                // "Invalid repo URL" would be false; say what happened instead.
                if (analyze.status == 429) show_try_it_limited();
            }).catch(error => console.log(error))
    } 
    return is_valid_repo;
}

function show_try_it_limited(){
    var limited = el("try-it-limited");
    if (limited) limited.style.display = "block";
    try_it_limited = true;
}

async function validate_and_submit(event){
    // The event was previously read off the window global rather than taken as
    // a parameter. That works in most browsers and is not something to rely on
    // for the page's only interactive control.
    var evt = event || window.event;
    if (evt) {
        evt.preventDefault();
        evt.stopPropagation();
    }

    var form = el("form");
    if (!form) return false;
    try_it_limited = false;
    disable_button();

    var encoded_url = get_encoded_url();
    var is_valid_url = await validate_url(encoded_url);

    if (is_valid_url) {
      form.action = `/url=${encoded_url}`;
      form.submit();
    } else if (try_it_limited) {
        enable_button();
    } else {
        display_error();
    }

    return false;
}

function languages_button_event(){
    document.addEventListener('DOMContentLoaded', function () {
    
        var dropdown = document.querySelector('.dropdown');
          
        dropdown.addEventListener('click', function(event) {
            event.stopPropagation();
            dropdown.classList.toggle('is-active');
                
        });    

        document.addEventListener('click', function(e) {
            dropdown.classList.remove('is-active');
        });
    });
}

function apply_risk_class(cell, value) {
    var span = document.createElement("span");
    span.textContent = value;
    switch(String(value).toLowerCase()){
        case "critical":
            span.className = "criticalrisk"; break;
        case "high":
            span.className = "highrisk"; break;
        case "medium":
            span.className = "mediumrisk"; break;
        case "low":
            span.className = "lowrisk"; break;
        // agentic_classification values
        case "agent":
            span.className = "criticalrisk"; break;
        case "mixed":
            span.className = "mediumrisk"; break;
        case "human":
            span.className = "lowrisk"; break;
        default: break;
    }
    cell.appendChild(span);
}

function format_percent(value) {
    if (value === null || value === undefined || value === "") return "N/A";
    return (parseFloat(value) * 100).toFixed(1) + "%";
}

function format_date(value) {
    if (!value) return "N/A";
    var d = new Date(value);
    if (isNaN(d.getTime())) return value;
    return d.toLocaleDateString();
}

// Every field below comes from a repository its owner controls -- commit
// author names, the default branch, the repo size string. They are written
// with textContent: writing them as HTML parsed a branch named
// `<img src=x onerror=...>` as an element and ran it.
function text_cell(cell, value) {
    cell.textContent = (value === null || value === undefined || value === "") ? "N/A" : String(value);
}

// Only http(s). A report's repo URL is data; as an href, `javascript:...`
// would run on click.
function safe_href(url) {
    return /^https?:\/\//i.test(String(url)) ? String(url) : null;
}

// Both report pages call this with the slug and the whole report, and the
// fields are read here. The templates used to read them and pass seventeen
// positional arguments; when agentic_classification was added to display_row
// the trending page's call was not updated, every later argument shifted by
// one, and json_data arrived undefined -- so its "view" button did nothing.
function display_report(slug, report) {
    var data = (report && report["data"]) || {};
    var results = data["results"] || {};
    var git = data["git"] || {};

    display_row(data["repo"], slug, data["risk"],
                results["contributor_count"], results["contributor_risk"],
                results["functional_contributors"], results["functional_contributors_risk"],
                results["large_recent_commit_risk"], results["recent_commit_size_in_percent_of_codebase"],
                results["commit_currency_weeks"], results["commit_currency_risk"],
                results["sbom_risk"], results["agentic_classification"], data["repo_size"],
                git["last_commit_date"], git["total_commits_on_default_branch"], git["default_branch"],
                report);
}

function display_row(project, slug, risk, ccount, contributor_risk, fccount, fc_risk,
                     large_commit_risk, recent_commit_pct, commit_currency, commit_currency_risk,
                     sbom_risk, agentic_classification, repo_size, last_commit, total_commits, default_branch, json_data) {
    var table = document.getElementById("repo")
    var row = table.insertRow(-1);
    row.className = "row";

    var columns = ["project", "risk", "ccount", "contributor_risk", "fccount", "fc_risk",
                   "large_commit_risk", "recent_commit_pct", "commit_currency", "commit_currency_risk",
                   "sbom_risk", "agentic_classification", "repo_size", "last_commit", "total_commits",
                   "default_branch", "json"];
    var cells = {};
    columns.forEach(function (name, i) {
        cells[name] = row.insertCell(i);
        cells[name].className = "table-data is-family-code " + name;
    });

    var href = safe_href(project);
    var label = document.createTextNode(slug);
    if (href) {
        var a = document.createElement("a");
        a.appendChild(label);
        a.href = href;
        a.setAttribute("target", "_blank");
        a.setAttribute("rel", "noopener noreferrer");
        cells["project"].appendChild(a);
    } else {
        cells["project"].appendChild(label);
    }

    var riskspan = document.createElement("span");
    riskspan.textContent = risk;
    switch(risk){
        case "critical":
            riskspan.className = "criticalrisk"; break;
        case "high":
            riskspan.className = "highrisk"; break;
        case "medium":
            riskspan.className = "mediumrisk"; break;
        case "low":
            riskspan.className = "lowrisk"; break;
        default: break;
    }
    cells["risk"].appendChild(riskspan);

    text_cell(cells["ccount"], ccount);
    apply_risk_class(cells["contributor_risk"], contributor_risk);
    text_cell(cells["fccount"], fccount);
    apply_risk_class(cells["fc_risk"], fc_risk);
    text_cell(cells["large_commit_risk"], large_commit_risk);
    text_cell(cells["recent_commit_pct"], format_percent(recent_commit_pct));
    text_cell(cells["commit_currency"], commit_currency);
    apply_risk_class(cells["commit_currency_risk"], commit_currency_risk);
    apply_risk_class(cells["sbom_risk"], sbom_risk);
    text_cell(cells["agentic_classification"], agentic_classification);
    text_cell(cells["repo_size"], repo_size);
    text_cell(cells["last_commit"], format_date(last_commit));
    text_cell(cells["total_commits"], total_commits);
    text_cell(cells["default_branch"], default_branch);

    // The full report is its own page. It was a JSON tree squeezed into this
    // column, unreadable at any width. The trending run cached the report, so
    // the page is served from cache.
    if (href) {
        var view = document.createElement("a");
        view.className = "button is-info is-small is-family-code";
        view.textContent = "view";
        view.href = "/url=" + encodeURIComponent(href);
        cells["json"].appendChild(view);
    }
}


