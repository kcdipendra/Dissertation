#' ---
#' title: "Survey completion rates"
#' author: "Andrew Heiss"
#' date: "`r format(Sys.time(), '%B %e, %Y')`"
#' output: 
#'   html_document: 
#'     css: ../html/fixes.css
#'     code_folding: hide
#'     toc: yes
#'     toc_float: true
#'     toc_depth: 4
#'     highlight: pygments
#'     theme: cosmo
#'     keep_md: yes
#'     self_contained: no
#'     includes:
#'       after_body: ../html/add_home_link.html
#' bibliography: /Users/andrew/Dropbox/Readings/Papers.bib
#' csl: /Users/andrew/.pandoc/csl/american-political-science-association.csl
#' ...

#' # Load and process all data
#+ message=FALSE
library(tidyverse)
library(stringr)
library(yaml)
library(pander)
library(ggrepel)
library(scales)
library(lubridate)
library(plotly)
library(DT)
library(countrycode)

panderOptions('table.split.table', Inf)
panderOptions('table.split.cells', Inf)
panderOptions('keep.line.breaks', TRUE)
panderOptions('table.style', 'multiline')
panderOptions('table.alignment.default', 'left')

options("readr.num_columns" = 0)

#+ message=FALSE
source(file.path(PROJHOME, "Analysis", "lib", "graphic_functions.R"))
source(file.path(PROJHOME, "Analysis", "lib", "cat_analysis.R"))

# Reproducibility
my.seed <- 1234
set.seed(my.seed)

# Bayesian stuff
CHAINS <- 4
ITER <-2000
WARMUP <- 1000
CORES <- parallel::detectCores()

options(mc.cores = CORES)


#' ## Dead addresses, domains, and bounces
# Clean IDs
clean.ids <- read_csv(file.path(PROJHOME, "Data", "Survey", "raw_data",
                                "clean_ids-2017-01-11.csv"))
# Load data from tracking database
db.email <- src_sqlite(path=file.path(PROJHOME, "Data", "Survey", "list", 
                                      "final_list.db"))
email.full <- tbl(db.email, "full_list") %>% collect() %>%
  separate(id_org, c("db", "id.in.db"))
removed <- tbl(db.email, "remove") %>% collect()
bounced.raw <- tbl(db.email, "bounces") %>% collect()
completed <- tbl(db.email, "survey_completed") %>% collect() %>%
  left_join(clean.ids, by=c("qualtrics_id" = "ResponseID"))
sending.groups <- tbl(db.email, "groups") %>% collect()

email.by.db <- email.full %>%
  group_by(db) %>%
  summarise(num.apparently.valid = n())

dead.searches <- paste(c("Hippo", "Invalid", "Dead", "weird opt"), collapse="|")
dead <- removed %>%
  filter(str_detect(remove_notes, regex(dead.searches, ignore_case=TRUE))) %>%
  select(fk_org, notes = remove_notes)

bounced <- bounced.raw %>%
  gather(notes, value, hard_bounce, email_dead, email_bounce) %>%
  filter(value != 0) %>%
  select(fk_org, notes)
  
dead.and.bounced <- bind_rows(dead, bounced) %>%
  group_by(fk_org) %>%
  slice(1) %>%  # Get rid of duplicate removal entries
  ungroup() %>%
  left_join(select(email.full, fk_org = index_org, db), by="fk_org")

dead.and.bounced.by.db <- dead.and.bounced %>%
  group_by(db) %>%
  summarise(num.dead.bounced = n())

# Load full survey data (minus the Q4\* loop for simplicity)
survey.orgs.all <- readRDS(file.path(PROJHOME, "Data", "data_processed", 
                                     "survey_orgs_all.rds"))

# Load cleaned, country-based survey data (*with* the Q4\* loop)
survey.clean.all <- readRDS(file.path(PROJHOME, "Data", "data_processed", 
                                      "survey_clean_all.rds"))

# Load cleaned, organization-based data (without the Q4 loop)
survey.orgs.clean <- readRDS(file.path(PROJHOME, "Data", "data_processed", 
                                       "survey_orgs_clean.rds"))

# Load cleaned, country-based data (only the Q4 loop)
survey.countries.clean <- readRDS(file.path(PROJHOME, "Data", "data_processed", 
                                            "survey_countries_clean.rds"))

# Load valid partial responses
survey.partials <- readRDS(file.path(PROJHOME, "Data", "data_processed", 
                                     "survey_partials.rds"))


#' ## Summarize response rates from each database
# Load YAML metadata for survey lists
raw.lists <- yaml.load_file(file.path(PROJHOME, "data", "data_raw",
                                      "NGO lists", "ngo_lists.yml"),
                            as.named.list=TRUE)

# Convert to nice dataframe with purrr::map_df()
list.details <- seq(1:length(raw.lists$lists)) %>%
  map_df(function(x) raw.lists$lists[[x]][c("title", 'name',
                                            "num_rows_raw", "description")]) %>%
  arrange(desc(num_rows_raw))

response.summary <- list.details %>%
  left_join(email.by.db, by=c("name" = "db")) %>%
  left_join(dead.and.bounced.by.db, by=c("name" = "db")) %>%
  mutate(num.invited = num.apparently.valid - num.dead.bounced) %>%
  select(-c(description))

response.summary.total <- response.summary %>%
  summarise_each(funs(sum), -title, -name) %>%
  mutate(title = "**Total**")

response.summary.with.total <- bind_rows(response.summary,
                                         response.summary.total) %>%
  select(-name) %>%
  mutate(perc.valid = num.apparently.valid / num_rows_raw,
         perc.bounced.from.valid = num.dead.bounced / num.apparently.valid,
         perc.invited.from.raw = num.invited / num_rows_raw,
         perc.invited.from.valid = num.invited / num.apparently.valid)

response.summary.display <- response.summary.with.total %>%
  mutate_at(vars(starts_with("num")), .funs=funs(comma)) %>%
  mutate_at(vars(starts_with("perc")), .funs=funs(percent))

response.summary.in.paper <- response.summary.display %>%
  select(Directory = title, `Listed` = num_rows_raw, 
         `Valid` = num.apparently.valid,
         `Bounced` = num.dead.bounced, `Invited` = num.invited,
         `% invited\n(listed)` = perc.invited.from.raw,
         `% invited\n(valid)` = perc.invited.from.valid)

caption <- "Number of valid and invited NGOs {#tbl:summary-list}"
clean.table <- pandoc.table.return(response.summary.in.paper,
                                   keep.line.breaks=TRUE, style="multiline",
                                   justify="lrrrrcc", caption=caption)

#+ results="asis"
cat(clean.table)
cat(clean.table, file=file.path(PROJHOME, "Output", "tables", 
                                "3-summary-list.md"))


#' Full technical details of how I ran the survey are available at my [research
#' notebook](https://notebook.andrewheiss.com/project/diss-ingos-in-autocracies/survey-technical-details/).
#' 
#' The complete database of NGOs to receive a survey invitation came from 
#' `r length(raw.lists$lists)` different sources. After collecting the details
#' of each organization listed at each source, I cleaned the raw lists by 
#' removing all organizations without valid e-mail addresses and by attempting 
#' to filter out obviously domestic NGOs. I filtered out domestic NGOs either 
#' by not collecting them in the first place (in the case of the Yearbook of
#' International Organizations), or using information from the database to
#' identify them. For example, the UN iCSCO database includes a field for an
#' organization's geographic scope: local, national, regional, and
#' international. I omitted local and national.
#' 
#' I filtered out invalid e-mail addresses using Email Hippo, which pings each
#' address to verify (1) that the domain exists, and (2) that the address
#' exists at the domain.
#' 
#+ echo=FALSE
# Cool use of DT::datatable: https://raw.githubusercontent.com/BuzzFeedNews/2016-04-federal-surveillance-planes/master/analysis.Rmd

#+ results="asis"
pandoc.table(response.summary.display)

#' Some databases were more responsive than others (though this is hardly
#' accurate; half of the responses aren't linked to specific databases):
survey.dbs <- survey.orgs.clean %>%
  group_by(database) %>%
  summarise(num.responses = n()) %>% 
  ungroup()

response.summary.actual <- survey.dbs %>%
  left_join(response.summary, by=c("database"="name")) %>%
  mutate(pct.responded.from.invited = num.responses / num.invited,
         pct.responded.clean = percent(pct.responded.from.invited)) %>%
  mutate(database = ifelse(database == "unknown", "zzzunknown", database),
         title = ifelse(is.na(title), "Unknown", title)) %>%
  arrange(database) %>%
  select(title, num.responses, num.invited, pct.responded.clean)

#+ results="asis"
pandoc.table(response.summary.actual)


#' ## ECOSOC-affiliated organizations
ecosoc.general <- read_csv(file.path(PROJHOME, "Data", "data_raw", 
                                     "NGO lists", "ECOSOC", "general.csv"))
ecosoc.roster <- read_csv(file.path(PROJHOME, "Data", "data_raw", 
                                    "NGO lists", "ECOSOC", "roster.csv"))
ecosoc.special <- read_csv(file.path(PROJHOME, "Data", "data_raw", 
                                     "NGO lists", "ECOSOC", "special.csv"))

ecosoc.all <- bind_rows(ecosoc.general, ecosoc.roster, ecosoc.special) %>%
  rename(org_name = organization)

icso <- email.full %>% filter(db == "icso")

icso.ecosoc <- icso %>% left_join(ecosoc.all, by="org_name") %>%
  filter(!is.na(affiliation))

#' Not all of the ECOSOC-affiliated ones are in here, since I only collected
#' regional and international organizations
#' 
nrow(icso.ecosoc)

#' How many of these are dead or bounced?
#' 
dead.ecosoc <- icso.ecosoc %>%
  filter(index_org %in% dead.and.bounced$fk_org)

#' 8% of ECOSOC-affiliated NGOs are dead
#' 
nrow(dead.ecosoc)
nrow(dead.ecosoc) / nrow(icso.ecosoc)

#' ## Figure out partials, incompletes, completes
#' 
#' Determine the best cutoff point for partially answered questions based on
#' the number of questions answered.
#' 
#' What was the minimum number of questions answered by an INGO that finished
#' the survey?
#' 
complete.ingos <- survey.orgs.all %>%
  filter(Finished == 1, Q2.4 == "Yes") %>%
  # Count of Q* questions answered
  mutate(num.answered = rowSums(!is.na(select(., starts_with("Q")))))

min(complete.ingos$num.answered)

#' Thus, my rough cut-off point for partials = 20. But with Q3.3 and Q3.8,
#' missing values are converted to "Not applicable", so even if a respondent
#' didn't ever see it, they'll get a recorded response for that question. This
#' means that there are 11 ghost responses that have to be ignored (5 in Q3.3,
#' 6 in Q3.8), so the technical cut-off point is 31.
#'
#' However, some respondents quit before answering any questions about the 
#' countries they work in. I count any respondent that answered more than six 
#' questions in the loop of country questions. I use six because of how the Q4
#' variables are generated and cleaned. If an organization answered Q4.1 (the
#' country name), the script converted it to COW and ISO codes, resulting in 3
#' valid Q4.1 questions. Additionally, the script converts text-based Q4
#' questions into characters and will sometimes yield NULL instead of NA, which
#' then gets counted in the number of questions (so it's possible for a
#' respondent to answer just the country name and have that count as 6
#' questions). Also, Q4.16 creates 6 ghost questions, so the limit is 
#' technically 12 (6 + 6).
#' 
#' So, I use a combination of factors to determine partiality. A respondent has
#' to answer at least 20 (31) questions, and at least 6 have to come from the
#' Q4 loop. This is a better, more robust cutoff than simply using a
#' 20-question minimum arbitrarily.
#' 
#' Thus, there are this many valid complete and partial responses:
#' 
nrow(survey.orgs.clean)
table(survey.orgs.clean$complete)


#' # Survey meta-metrics
#' 
#' ## Absorption rate
#' 
#' > The absorption rate [measures] the ability of the survey company to manage
#' and keep up-to-date their database of email addresses and communications
#' with panel members [@CallegaroDiSogra:2008, 1026].
#' 
#' $$
#' \frac{EI - BB - NET}{EI}
#' $$
#' 

EI <- response.summary.total$num.apparently.valid
BB.NET <- response.summary.total$num.dead.bounced

absorption.rate <- (EI - BB.NET) / EI

#' - EI = e-mail invitations sent: `r comma(EI)`
#' - BB = bounced: `r comma(BB.NET)`
#' - NET = network undeliverable: included in `BB`
#' - **Absorption rate:** `r percent(absorption.rate)`
#' 


#' ## Break-off rate
#' 
#' > The break-off rate is a possible indicator of problems in the design of
#' the questionnaire (e.g., too long, boring…) or struggle with technical
#' problems during the survey administration (e.g., streaming media or
#' animations that may “break” a survey at some point) 
#' [@CallegaroDiSogra:2008, 1026].
#' 
#' $$
#' \frac{BO}{I + P + BO}
#' $$
#' 

# Only consider the organizations that were not screened out
survey.orgs.ingos <- survey.orgs.all %>%
  filter(Q2.4 == "Yes") %>%
  left_join(clean.ids, by="ResponseID")

BO <- survey.orgs.ingos %>%
  filter(!(ResponseID %in% unique(survey.partials$ResponseID))) %>%
  filter(!(clean.id %in% unique(survey.clean.all$clean.id))) %>%
  select(ResponseID) %>% unique() %>% nrow() %>% unlist()

I.survey <- survey.clean.all %>%
  filter(Finished == 1) %>% select(clean.id) %>% 
  unique() %>% nrow() %>% unlist()

P.survey <- length(unique(survey.partials$ResponseID))

break.off.rate <- BO / (I.survey + P.survey + BO)

#' - BO = number of surveys broken off (i.e. incomplete and 
#'   not partial): `r comma(BO)`
#' - I = complete: `r comma(I.survey)`
#' - P = partial: `r comma(P.survey)`
#' - **Break-off rate:** `r percent(break.off.rate)` 
#' 

#' ## Completion rate (participation rate)
#'
#' > The most intuitive response metric is the survey's completion rate. It is
#' also the one metric most often mislabeled as a response rate. The completion
#' rate is the proportion of those who completed the Web survey among all the
#' eligible panel members who were invited to take the survey
#' [@CallegaroDiSogra:2008, 1021-22].
#'
#' > Using such a rate as an indicator of possible nonresponse error makes
#' little sense; however, the participation rate may serve as a useful
#' indicator of panel efficiency [@AAPOR:2016, 49].
#' 
#' $$
#' \frac{I + P}{(I + P) + (R + NC + O)}
#' $$
#' 

# Number who refused (i.e. explicitly did not give consent)
R.survey <- survey.orgs.all %>%
  select(Q6.1) %>%
  filter(!is.na(Q6.1)) %>%
  nrow() %>% unlist()

#' Non-contact is impossible to determine, since I don't know how many
#' organizations self-screened without taking the survey or e-mailing me. So,
#' this participation rate is not accurate, but no participation rate ever is.
NC <- response.summary.total$num.invited - nrow(survey.orgs.all)

participation.rate <- (I.survey + P.survey) / 
  (I.survey + P.survey + BO + R.survey + NC)

#' - I = complete: `r comma(I.survey)`
#' - P = partial: `r comma(P.survey)`
#' - R = refusal and break-off: `r comma(BO)` (break-off) and 
#'   `r comma(R.survey)` (refusal)
#' - NC = non-contact: `r comma(NC)`
#' - O = other: None
#' - **Participation rate**: `r percent(participation.rate)`
#' 


#' ## Study-specific screening completion rates
#' 
#' > Study-specific screening completion rates and eligibility rates measure
#' the incidence of a particular phenomenon among panel members. When these
#' rates are significantly different from an external "gold standard," they may
#' indicate issues of question wording in the screener module or respondents
#' purposively self-selecting themselves for a particular study (e.g., to gain
#' rewards) even if they do not really qualify.… These rates may also reveal a
#' skew in the panel membership along a particular dimension that may raise
#' concerns regarding bias [@CallegaroDiSogra:2008, 1026].
#' 
#' $$
#' \frac{SCQ + SCNQ}{INV}
#' $$
#' 

SCQ <- survey.orgs.all %>%
  filter(Q2.4 == "Yes") %>%
  select(ResponseID) %>%
  unique() %>% nrow() %>% unlist()

SCNQ <- survey.orgs.all %>%
  filter(Q2.4 == "No") %>%
  select(ResponseID) %>%
  unique() %>% nrow() %>% unlist()

INV <- response.summary.total$num.invited

screening.completion.rate <- (SCQ + SCNQ) / INV

#' - SCQ = screening completed and qualified: `r comma(SCQ)`
#' - SCNQ = screening completed and not qualified (i.e. screened out): `r comma(SCNQ)`
#' - INV = survey invitations sent out: `r comma(INV)`
#' - **Study-specific screening completion rate**: `r percent(screening.completion.rate)`
#' 


#' ## Study-specific eligibility rate
#' 
#' > The problem with a screening rate is that nonresponse is confounded with
#' the screening. In fact, we do not know if a person qualifies unless they
#' provide that information by answering the screening questions. For this
#' reason, we talk about screening completion rate and not screening rate
#' [@CallegaroDiSogra:2008, 1023].
#' 
#' $$
#' \frac{SCQ}{SCQ + SCNQ}
#' $$
#' 

study.eligibility.rate <- SCQ / (SCQ + SCNQ)

#' - SCQ = screening completed and qualified: `r comma(SCQ)`
#' - SCNQ = screening completed and not qualified (i.e. screened out): `r comma(SCNQ)`
#' - **Study-specific eligibility rate**: `r percent(study.eligibility.rate)`
#' 


#' # Other details
#' 
#' > In addition to these rates, we also believe that it is the best practice
#' to report the length of the field period with its start and close dates, the
#' number of reminders sent and their form (email, letter, IVR call, or
#' personal call), and the use of any incentive [@CallegaroDiSogra:2008, 1026].
#' 
#' ## Timeline of e-mail invitations
invited.groups.summary <- email.full %>%
  filter(!(index_org %in% dead.and.bounced$fk_org)) %>%
  mutate(id_group = as.integer(group)) %>%
  group_by(id_group) %>%
  summarise(num.in.group = n())

sending.groups.summary <- sending.groups %>%
  left_join(invited.groups.summary, by="id_group") %>%
  # Because I stupidly didn't include a final reminder column, I put the
  # timestamp of the final reminder in the notes column. This extracts the
  # timestamp with a regex.
  mutate(email_final_reminder = 
           str_extract(notes, "\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}")) %>%
  mutate_at(vars(starts_with("email")), funs(ymd_hms)) %>%
  gather(email_type, email_date, starts_with("email")) %>%
  # Make Group 9's reminder be the final reminder
  mutate(email_type = ifelse(email_type == "email_reminder" & id_group == 9,
                             "email_final_reminder", email_type))


make_range <- function(x) {
  if (length(x) == 1) {
    return(paste("Group", as.character(x)))
  } else {
    return(paste0("Groups ", min(x), "-", max(x)))
  }
}

sending.groups.plot <- sending.groups.summary %>%
  filter(!is.na(email_date)) %>%
  mutate(email_day = ceiling_date(email_date, unit="day")) %>%
  filter(!is.na(email_day)) %>%
  group_by(email_day, email_type) %>%
  summarise(emails_sent = sum(num.in.group),
            group_names = make_range(id_group)) %>%
  ungroup() %>%
  mutate(total = cumsum(emails_sent),
         email_type = factor(email_type, 
                             levels=c("email_invitation", "email_reminder", 
                                      "email_final_reminder"),
                             label=c("Invitation  ", "Reminder  ", "Final reminder"),
                             ordered=TRUE))

plot.timeline <- ggplot(sending.groups.plot, aes(x=email_day, y=total)) +
  geom_step(size=0.5, colour="grey50") + 
  scale_y_continuous(labels=comma) +
  scale_x_datetime(date_labels="%B %e", date_breaks="1 week") +
  guides(fill=FALSE, colour=guide_legend(title=NULL)) +
  labs(x=NULL, y="Approximate total number of emails") +
  theme_light()

plot.timeline.static <- plot.timeline + 
  geom_point(aes(color=email_type)) + 
  geom_label_repel(aes(label=group_names, fill=email_type),
                   size=2.5, colour="white") +
  theme(legend.position="bottom", 
        legend.key.size=unit(0.65, "lines"),
        legend.key=element_blank(),
        panel.grid.minor=element_blank())

plot.timeline.interactive <- plot.timeline +
  geom_point(aes(color=email_type, text=group_names))

ggplotly(plot.timeline.interactive)


#' ## Timeline of survey responses
survey.time.plot <- survey.orgs.clean %>%
  select(EndDate) %>%
  arrange(EndDate) %>%
  mutate(done = 1,
         num.completed.cum = cumsum(done))

plot.responses.timeline <- ggplot() + 
  geom_step(data=survey.time.plot,
            aes(x=EndDate, y=num.completed.cum),
            size=0.5, colour="grey50") + 
  scale_y_continuous(labels=comma) +
  scale_x_datetime(date_labels="%B %e", date_breaks="1 week") +
  guides(fill=FALSE, colour=guide_legend(title=NULL)) +
  labs(x="2016", y="Cumulative number of responses") +
  theme_light()

plot.responses.timeline.static <- plot.responses.timeline +
  geom_vline(data=sending.groups.plot,
             aes(xintercept=as.numeric(email_day),
                 colour=email_type),
             size=0.5) +
  # geom_label_repel(data=sending.groups.plot,
  #                  aes(x=email_day, y=400, 
  #                      label=group_names, fill=email_type),
  #                  size=2.5, colour="white") +
  theme_ath() +
  theme(panel.grid.minor=element_blank(),
        axis.text.x=element_text(angle=45, hjust=1))
plot.responses.timeline.static

fig.save.cairo(plot.responses.timeline.static,
               filename="survey-timeline-static",
               width=5.5, height=3.5)

plot.responses.timeline.interactive <- plot.responses.timeline +
  geom_vline(data=sending.groups.plot, 
             aes(xintercept=as.numeric(email_day), 
                 colour=email_type, text=group_names),
             size=0.5)

ggplotly(plot.responses.timeline.interactive)


#' # Differences between responders and nonresponders
#' 
#' Checking for differences between responders and nonresponders is really
#' tricky since (1) the final database didn't always have information about
#' survey HQ countries or target countries, (2) not all respondents could be
#' matched with their entires in the master list of all invited organizations,
#' and (3) respondent answers don't always match up with what's in the list—for
#' instance, an organization listed by the YIO as based in one country might
#' answer as being based in another.
#' 
#' So, this analysis here is very, very rough and shows how representative home
#' countries might be in general. It can't check how representative issues are,
#' since issues aren't really well known, and it can't check how representative
#' target countries are for the same reason.
#' 
#' With all those caveats, it seems that in general, more American and European
#' NGOs responded than those from Asia and Africa.
#' 

# Get a list of ids of completed surveys
completed.and.partial <- completed %>%
  filter(clean.id %in% survey.orgs.clean$clean.id) %>%
  left_join(select(survey.orgs.clean, clean.id, Q2.2_country),
            by="clean.id")

# Get full list of invited organizations with a column indicating the ones that
# completed the survey. This is not completely accurate since not every
# response was matchable with its database entry—it actually undercounts by a
# lot. But it should give a rough approximation.
all.invited <- email.full %>%
  filter(!(index_org %in% dead.and.bounced$fk_org)) %>%
  mutate(completed = index_org %in% completed.and.partial$fk_org) %>%
  left_join(select(completed.and.partial, index_org=fk_org, Q2.2_country), by="index_org") %>%
  mutate(country_hq_real = ifelse(completed, Q2.2_country, country_hq)) %>%
  mutate(region_hq = countrycode(country_hq_real, "country.name", "continent"))

#' How many completed responses are missing from this analysis?
#' 
nrow(survey.orgs.clean) - sum(all.invited$completed)
# ¯\_(ツ)_/¯

#' Associational statistics for respondents and nonrespondents:
#' 
responses.hq.region <- all.invited %>%
  xtabs(~ region_hq + completed, .)

#+ results="markup"
analyze.cat.var(responses.hq.region)

# Bayesian stuff just for fun
responses.hq.region.bayes <- all.invited %>%
  count(region_hq, completed) %>%
  filter(!is.na(region_hq)) %>%
  group_by(region_hq) %>%
  mutate(total = sum(n)) %>%
  ungroup() %>%
  filter(completed) %>%
  mutate(region_hq = factor(region_hq)) %>%
  diff.groups.bayes(cbind(n, total) ~ region_hq, data=., prop=TRUE)

#+ fig.width=6, fig.height=2
responses.hq.region.bayes$plot.groups

#+ fig.width=6, fig.height=4
responses.hq.region.bayes$plot.diffs

responses.hq.region.bayes$diffs.summary %>% 
  datatable(extensions="Responsive") %>%
  formatSignif(2:8)

#' # References
#' 
