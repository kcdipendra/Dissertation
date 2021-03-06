#' ---
#' title: "LNA-based case selection for SNA"
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
#'     self_contained: no
#'     includes:
#'       after_body: ../html/add_home_link.html
#' ---

#+ load_data_libraries, message=FALSE
knitr::opts_chunk$set(cache=FALSE, fig.retina=2,
                      tidy.opts=list(width.cutoff=120),  # For code
                      options(width=120))  # For output

# Load libraries
# library(printr)
library(tidyverse)
library(DT)
library(countrycode)
library(rstanarm)
library(ggrepel)

source(file.path(PROJHOME, "Analysis", "lib", "graphic_functions.R"))
coef.names <- coef.names %>%
  filter(term != "icrg.pol.risk.internal.scaled") %>%
  filter(term != "shaming.ingos.std")

# Load data
models.bayes <- readRDS(file.path(PROJHOME, "Data", "data_processed",
                                  "models_to_keep.rds"))

autocracies <- readRDS(file.path(PROJHOME, "Data", "data_processed",
                                 "autocracies.rds"))

# General settings
my.seed <- 1234
set.seed(my.seed)


#' # LNA-based case selection
#' 
#' ## Issues with list-wise deletion
#' 
#' Missing data makes perfect LNA selection based on predicted values 
#' tricky—there are lots of instances where there's not enough data to get lots
#' of predicted values. `lna.JGI.b` is the most complete model, but even then, 
#' it omits lots of observations, mostly because ICRG doesn't cover everything.
#' Someday I need to figure out how to correctly impute data for Bayesian
#' models (i.e. not use Amelia).
#' 
model.for.case.selection <- filter(models.bayes,
                                   model.name == "lna.JGI.b")$model[[1]]

rows.used <- as.numeric(rownames(model.for.case.selection$model))
vars.used <- Filter(function(x) !str_detect(x, "as\\.factor"),
                    colnames(model.for.case.selection$model))

autocracies.modeled <- autocracies %>%
  mutate(rowname = row_number(),
         in.model = rowname %in% rows.used) %>%
  filter(year.num > 1994) %>%
  select(rowname, in.model, cowcode, country, year.num, one_of(vars.used))

datatable(autocracies.modeled, extensions="Responsive") %>%
  formatRound(vars.used)

#' ## Predicted vs. actual CSRE
cases <- data_frame(cowcode = c(710, 651, 365),
                    country.name = countrycode(cowcode, "cown", "country.name"),
                    colour = ath.palette("palette1", n=3),
                    fill = ath.palette("palette1", n=3),
                    linetype = 1, alpha = 1, point.size = 1) %>%
  mutate(country.name = ifelse(cowcode == 365, "Russia", country.name))

plot.data.sna.selection <- model.for.case.selection %>%
  augment() %>%
  mutate(post.pred.fit = apply(posterior_predict(model.for.case.selection, 
                                                 seed=my.seed), 2, median)) %>%
  mutate(.rownames = as.numeric(.rownames)) %>%
  left_join(select(autocracies.modeled, rowname, cowcode, country),
            by=c(".rownames" = "rowname")) %>%
  left_join(cases, by="cowcode") %>%
  mutate(country.name = ifelse(is.na(country.name), "Other", country.name),
         colour = ifelse(is.na(colour), "grey70", colour),
         fill = ifelse(is.na(fill), NA, fill),
         linetype = ifelse(is.na(linetype), 0, linetype),
         alpha = ifelse(is.na(alpha), 0.25, alpha),
         point.size = ifelse(is.na(point.size), 0.55, point.size)) %>%
  mutate(country.name = factor(country.name, levels=c(cases$country.name, "Other"),
                               ordered=TRUE),
         colour = factor(colour, levels=c(cases$colour, "grey70"),
                         ordered=TRUE),
         fill = factor(fill, levels=c(cases$fill, NA),
                       ordered=TRUE))

plot.sna.selection <- ggplot(plot.data.sna.selection,
                             aes(x=post.pred.fit, y=cs_env_sum.lead,
                                 colour=colour)) +
  geom_segment(x=-6, xend=6, y=-6, yend=6, colour="grey75", size=0.5) +
  geom_point(aes(alpha=alpha, size=point.size)) +
  # stat_ellipse(aes(linetype=linetype), type="norm", size=0.5) +
  stat_chull(aes(linetype=linetype, fill=fill), alpha=0.1, show.legend=FALSE) +
  stat_smooth(aes(linetype=linetype, colour=colour), method="lm", se=FALSE, linetype="dashed") +
  scale_color_identity(guide="legend", labels=c(cases$country.name, "Other"),
                       name=NULL) +
  scale_fill_identity() +
  scale_size_identity() +
  scale_alpha_identity() +
  scale_linetype_identity() +
  labs(x="Predicted CSRE", y="Actual CSRE") +
  coord_cartesian(xlim=c(-4, 4), ylim=c(-6, 6)) +
  theme_ath()
plot.sna.selection

fig.save.cairo(plot.sna.selection,
               filename="2-sna-selection",
               width=4.5, height=3.5)

#' ## Data for case studies
#' 
#' Calculate the average level of each variable used in the two models and the
#' corresponding percentile to determine how low/high the value is compared to
#' all other average countries. This isn't the most accurate way, since it
#' doesn't account for time, but it's a good start. To create the final
#' typological table of expected outcomes, [consult the timelines for each
#' country](timelines.html).
#'
# Get all variables from both models
both.models <- filter(models.bayes, model.name %in% c("lna.JGI.b", "lna.EHI.b"))$model
all.column.names <- sapply(1:length(both.models),
                           function(x) colnames(both.models[[x]]$model)) %>%
  unlist() %>% Filter(function(x) !str_detect(x, "as\\.factor"), .) %>% unique()

# Calculate summary statistics and rankings/percentiles for all countries
var.summaries.rankings <- autocracies %>%
  group_by(country) %>%
  summarise_at(funs(XXmin = min(., na.rm=TRUE),
                    XXmax = max(., na.rm=TRUE),
                    XXmean = mean(., na.rm=TRUE),
                    XXsd = sd(., na.rm=TRUE)),
               .cols=vars(one_of(all.column.names))) %>%
  mutate_at(funs(percentile = cume_dist(.),  # basically ecdf()
                 pct_rank = percent_rank(.)),
            .cols=vars(dplyr::contains("mean"))) %>%
  gather(key, value, -country) %>%
  separate(key, c("term", "key"), sep="_XX")

# Create really really wide dataframe with one row per case and all summary
# variables as columns
case.studies <- var.summaries.rankings %>%
  filter(country %in% cases$country.name) %>%
  unite(bloop, term, key) %>%
  spread(bloop, value)

# Only look at the percentile columns
final.case.studies <- case.studies %>%
  select(country, dplyr::contains("percentile"))

# Remove the _mean_percentile string from each column name so I can use
# one_of() to select the appropriate columns (since there's no
# starts_with_one_of() verb in dplyr)
final.case.studies.temp <- final.case.studies %>%
  rename_(.dots = setNames(colnames(.), 
                           str_replace(colnames(.), "_mean_percentile", "")))

#' ### Average values in whole distribution
df.distributions.plot <- autocracies %>%
  select(one_of(all.column.names)) %>%
  gather(variable, value) %>%
  filter(!is.na(value)) %>%
  left_join(coef.names, by=c("variable" = "term"))

df.case.means <- case.studies %>%
  select(country, dplyr::ends_with("mean")) %>%
  gather(variable, value, -country) %>%
  mutate(variable = str_replace(variable, "_mean", "")) %>%
  filter(!is.na(value)) %>%
  left_join(coef.names, by=c("variable" = "term"))

plot.cases.in.distributions <- ggplot(df.distributions.plot, aes(x=value)) +
  geom_density(aes(fill=category), colour=NA) + 
  geom_vline(data=df.case.means, aes(xintercept=value), size=0.25) +
  geom_text_repel(data=df.case.means, aes(label=country, y=0),
                  size=2.5) +
  guides(fill="none") +
  labs(x=NULL, y=NULL) +
  facet_wrap(~ term.short, scales="free", ncol=2) + 
  theme_ath()

#+ fig.width=6, fig.height=10
plot.cases.in.distributions


#' ### Actual and predicted CSRE
#' 
# TODO: Get predicted CSRE too
csre.pred.table <- plot.data.sna.selection %>%
  select(country, cs_env_sum.lead, post.pred.fit) %>%
  filter(country %in% cases$country.name) %>%
  group_by(country) %>%
  summarise_at(funs(mean = mean(., na.rm=TRUE)), .cols=vars(-country)) %>%
  left_join(select(final.case.studies, country,
                   cs_env_sum.lead.full.data_mean_pct = cs_env_sum.lead_mean_percentile),
            by="country") 

csre.pred.table %>%
  datatable() %>% formatRound(2:4) %>%
  formatStyle("cs_env_sum.lead_mean", 
              background=styleColorBarCentered(csre.pred.table$cs_env_sum.lead_mean, 
                                               "#FF4136", "#2ECC40")) %>%
  formatStyle("post.pred.fit_mean", 
              background=styleColorBarCentered(csre.pred.table$post.pred.fit_mean, 
                                               "#FF4136", "#2ECC40")) %>%
  formatStyle("cs_env_sum.lead.full.data_mean_pct", 
              background=styleColorBar(csre.pred.table$cs_env_sum.lead.full.data_mean_pct,
                                       "#0074D9", angle=-90))

#' ### Internal risk
#' 
#+ warning=FALSE
percentile.table.internal <- final.case.studies.temp %>%
  select(country, one_of(filter(coef.names, category == "Internal")$term))

percentile.table.internal %>%
  datatable() %>% formatRound(2:6) %>%
  formatStyle(2:6, background=styleColorBar(0:1, "#0074D9", angle=-90))

#' ### External risk
#' 
precentile.table.external <- final.case.studies.temp %>%
  select(country, one_of(filter(coef.names, category == "External")$term))

precentile.table.external %>%
  datatable() %>% formatRound(2:5) %>%
  formatStyle(2:5, background=styleColorBar(0:1, "#0074D9", angle=-90))

#' ### International shaming
#' 
#+ warning=FALSE
percentile.table.shaming <- final.case.studies.temp %>%
  select(country, one_of(filter(coef.names, category == "Shaming")$term)) 

percentile.table.shaming %>%
  datatable() %>% formatRound(2) %>%
  formatStyle(2, background=styleColorBar(0:1, "#0074D9", angle=-90))


#' ### By country
percentile.table.by.country <- final.case.studies.temp %>%
  gather(variable, value, -country) %>%
  spread(country, value) %>%
  left_join(coef.names, by=c("variable" = "term")) %>%
  select(term.clean, category, 2:7) %>%
  arrange(category, term.clean)

percentile.table.by.country %>%
  datatable() %>% formatRound(3:8) %>%
  formatStyle(3:8, background=styleColorBar(0:1, "#0074D9", angle=-90))


#' ## Expected and actual outcomes
#' 
#' ### CSRE-enabling factors (😃)
#' 
#' Internal environment:
#' 
#' - Government stability low
#' - Political stability high
#' - Fewer years in office
#' - Fewer years since election
#' - Opposition vote share high
#' 
#' External environment:
#' 
#' - Neighbors more unstable
#' - Coups in neighbors
#' - No violent protests in neighbors
#' - Nonviolent protests in neighbors
#' 
#' Reputational environment:
#' 
#' - State-based shaming?
#' 
#' 
#' ### CSRE-restricting factors (😡)
#' 
#' Internal environment:
#' 
#' - Government stability high
#' - Political stability low
#' - More years in office
#' - More years since election
#' - Opposition vote share low
#' 
#' External environment:
#' 
#' - Neighbors more stable
#' - No coups in neighbors
#' - Violent protests in neighbors
#' - No nonviolent protests in neighbors
#' 
#' Reputational environment:
#' 
#' - State-based shaming?
#'
#'
#' ### Basic trends
#' 
#' #### Egypt
#' 
#' - 😡 Political stability - medium
#' - 😡 Government stability - medium
#' - 😡 Years in office - high (low after 2011)
#' - 😃 Years since election - low
#' - 😡 Opposition vote share - low
#' - 😃 Neighbor political stability - medium (low after 2011)
#' - 😃 Neighbor coup activity - medium
#' - 😡 Neighbor violent protests - medium (high after 2011)
#' - 😃 Neighbor nonviolent protests - medium (high after 2011)
#' - State-based shaming - medium (high after 2005)
#' 
#' - Internal stability - low (−3)
#' - External stability - moderate, then low
#' - International reputation/shaming - high
#' 
#' #### China
#' 
#' - 😃 Political stability - high
#' - 😡 Government stability - medium high
#' - 😃 Years in office - low
#' - 🚫 Years since election - none
#' - 😡 Opposition vote share - low
#' - 😡 Neighbor political stability - medium
#' - 😃 Neighbor coup activity - medium
#' - 😃 Neighbor violent protests - low
#' - 😃 Neighbor nonviolent protests - medium
#' - State-based shaming - high
#' 
#' - Internal stability - moderate (0)
#' - External stability - high
#' - International reputation/shaming - high
#' 
#' #### Russia
#' 
#' - 😡 Political stability - medium
#' - 😡 Government stability - medium
#' - 😃 Years in office - high (technically low, but they're a weird case because Putin has been president twice and he was shadow president with Medvedev)
#' - 😃 Years since election - low
#' - 😃 Opposition vote share - high
#' - 😡 Neighbor political stability - high
#' - 😃 Neighbor coup activity - medium
#' - 😃 Neighbor violent protests - low
#' - 😃 Neighbor nonviolent protests - medium
#' - State-based shaming - low
#' 
#' - Internal stability - moderate (−1)
#' - External stability - high
#' - International reputation/shaming - low
#' 
#' ### Table
#' 
#' Based on this table and the timelines, here's the typological table of
#' expected outcomes for each case study country:
#' 
#+ message=FALSE
expected.outcomes <- read_csv(file.path(PROJHOME, "Analysis", 
                                        "country_case_studies", 
                                        "expected_outcomes.csv"))

caption <- "Expected and actual outcomes with all restricting and enabling factors {#tbl:expected-outcomes-full}"
outcomes <- pandoc.table.return(select(expected.outcomes, -Country), keep.line.breaks=TRUE,
                                justify="lllll", caption=caption, style="grid")

#+ results="asis"
cat(outcomes)
cat(outcomes, file=file.path(PROJHOME, "Output", "tables", 
                             "2-expected-outcomes-full.md"))


#' Simpler table
expected.outcomes.simple <- expected.outcomes %>%
  filter(Country != "")

caption <- "Expected and actual outcomes, simple {#tbl:expected-outcomes-simple}"
outcomes <- pandoc.table.return(expected.outcomes.simple, keep.line.breaks=TRUE,
                                justify="llllll", caption=caption, style="simple")

#+ results="asis"
cat(outcomes)
cat(outcomes, file=file.path(PROJHOME, "Output", "tables", 
                             "2-expected-outcomes-simple.md"))
