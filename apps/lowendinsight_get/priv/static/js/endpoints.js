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

function view_json_button(json_data, parent){
    var button_text = "view";
    
    var spanbutton = document.createElement("span");
    var button = document.createElement("Button");
    if (window.matchMedia('(max-device-width: 768px)').matches) {
        button.className = "button is-info is-small is-family-code";
    } else {
        button.className = "button is-info is-family-code";   
    }
    spanbutton.innerHTML = button_text;
    spanbutton.style["font-weight"] = "bold";
    button.appendChild(spanbutton);
    parent.appendChild(button);

    var div = document.createElement("div");
    div.className = "box tree";
    div.style.display = "none";
    var tree = jsonTree.create(json_data, div);
    parent.appendChild(div);

    button.addEventListener('click', () => {
        if (div.style.display == "none") {
            spanbutton.textContent = "hide";
            div.style.display = "block";
        } else {
            spanbutton.textContent = button_text;
            tree.collapse();
            div.style.display = "none";
        }
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

// agentic_classification, agentic_contribution_ratio, and restricted_contributors
// are rendered automatically by view_json_button's JSON tree viewer.

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

function display_row(project, slug, risk, ccount, contributor_risk, fccount, fc_risk,
                     large_commit_risk, recent_commit_pct, commit_currency, commit_currency_risk,
                     sbom_risk, agentic_classification, repo_size, last_commit, total_commits, default_branch, json_data) {
    var table = document.getElementById("repo")
    var row = table.insertRow(-1);
    row.className = "row";

    var i = 0;
    var project_cell = row.insertCell(i++);
    var risk_cell = row.insertCell(i++);
    var ccount_cell = row.insertCell(i++);
    var contributor_risk_cell = row.insertCell(i++);
    var fccount_cell = row.insertCell(i++);
    var fc_risk_cell = row.insertCell(i++);
    var large_commit_risk_cell = row.insertCell(i++);
    var recent_commit_pct_cell = row.insertCell(i++);
    var ccurreny_cell = row.insertCell(i++);
    var commit_currency_risk_cell = row.insertCell(i++);
    var sbom_risk_cell = row.insertCell(i++);
    var agentic_classification_cell = row.insertCell(i++);
    var repo_size_cell = row.insertCell(i++);
    var last_commit_cell = row.insertCell(i++);
    var total_commits_cell = row.insertCell(i++);
    var default_branch_cell = row.insertCell(i++);
    var json_cell = row.insertCell(i++);

    project_cell.className = "table-data is-family-code project";
    risk_cell.className = "table-data is-family-code risk";
    ccount_cell.className = "table-data is-family-code ccount";
    contributor_risk_cell.className = "table-data is-family-code contributor_risk";
    fccount_cell.className = "table-data is-family-code fccount";
    fc_risk_cell.className = "table-data is-family-code fc_risk";
    large_commit_risk_cell.className = "table-data is-family-code large_commit_risk";
    recent_commit_pct_cell.className = "table-data is-family-code recent_commit_pct";
    ccurreny_cell.className = "table-data is-family-code commit_currency";
    commit_currency_risk_cell.className = "table-data is-family-code commit_currency_risk";
    sbom_risk_cell.className = "table-data is-family-code sbom_risk";
    agentic_classification_cell.className = "table-data is-family-code agentic_classification";
    repo_size_cell.className = "table-data is-family-code repo_size";
    last_commit_cell.className = "table-data is-family-code last_commit";
    total_commits_cell.className = "table-data is-family-code total_commits";
    default_branch_cell.className = "table-data is-family-code default_branch";
    json_cell.className = "table-data is-family-code json";

    var a = document.createElement("a");
    var link = document.createTextNode(slug);
    a.appendChild(link);
    a.href = project;
    a.setAttribute("target", "_blank");
    project_cell.appendChild(a);

    var riskspan = document.createElement("span");
    riskspan.innerHTML = risk;
    risk_cell.appendChild(riskspan);

    ccount_cell.innerHTML = ccount;
    apply_risk_class(contributor_risk_cell, contributor_risk);
    fccount_cell.innerHTML = fccount;
    apply_risk_class(fc_risk_cell, fc_risk);
    large_commit_risk_cell.innerHTML = large_commit_risk;
    recent_commit_pct_cell.innerHTML = format_percent(recent_commit_pct);
    ccurreny_cell.innerHTML = commit_currency;
    apply_risk_class(commit_currency_risk_cell, commit_currency_risk);
    apply_risk_class(sbom_risk_cell, sbom_risk);
    agentic_classification_cell.innerHTML = agentic_classification || "N/A";
    repo_size_cell.innerHTML = repo_size || "N/A";
    last_commit_cell.innerHTML = format_date(last_commit);
    total_commits_cell.innerHTML = total_commits || "N/A";
    default_branch_cell.innerHTML = default_branch || "N/A";

    switch(risk){
        case "critical":
            riskspan.className += " criticalrisk"; break;
        case "high":
            riskspan.className += " highrisk"; break;
        case "medium":
            riskspan.className += " mediumrisk"; break;
        case "low":
            riskspan.className += " lowrisk"; break;
        default: break;
    }

    view_json_button(json_data, json_cell);
}


