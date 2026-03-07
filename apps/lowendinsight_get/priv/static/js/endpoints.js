function disable_button(){
    var button = document.getElementById("analyze-button");
    button.classList.add("is-loading");
    button.setAttribute("disabled", true);
}

function get_encoded_url(){
    var input = document.getElementById("input-url");
    var url = input.value;
    return encodeURIComponent(url);
}

function display_error() {
    document.getElementById("analyze-button").classList.remove("is-loading");
    document.getElementById("input-url").classList.add("error");
    document.getElementById("invalid-url").style.display = "block";
}

function remove_error(){
    document.getElementById("input-url").classList.remove("error");
    document.getElementById("invalid-url").style.display = "none";
    document.getElementById("analyze-button").disabled = false;
    document.getElementById("analyze-button").classList.remove("is-loading");
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
            }).catch(error => console.log(error))
    } 
    return is_valid_repo;
}

async function validate_and_submit(){
    event.preventDefault();
    event.stopPropagation();

    var form = document.getElementById("form");
    disable_button();

    var encoded_url = get_encoded_url();
    var is_valid_url = await validate_url(encoded_url);

    if (is_valid_url) {
      form.action = `/url=${encoded_url}`;
      form.submit();
    } else {
        display_error();
    }
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

function display_row(project, slug, risk, ccount, contributor_risk, fccount, fc_risk,
                     large_commit_risk, recent_commit_pct, commit_currency, commit_currency_risk,
                     sbom_risk, repo_size, last_commit, total_commits, default_branch, json_data) {
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


