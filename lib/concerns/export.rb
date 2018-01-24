# require 'debugger'; 

module Concerns::Export
  require 'yaml'

  extend ActiveSupport::Concern
  include LoaderHelper

  STANDARD_CALENDAR = YAML::load_file(File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'config', 'standard_calendar.yaml')))
  FIELD_IDS = YAML::load_file(File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'config', 'field_id.yaml')))

  def self.week_days calendar
    week_days = {}
    calendar['week_days'].each do |week_day| 
      day_type = week_day['day_type'];
      week_days[day_type] = week_day unless day_type == 0
    end
    week_days
  end

  STANDARD_WEEK_DAYS = self.week_days STANDARD_CALENDAR
  

  def generate_xml
    @uid = 1
    get_sorted_query
    @resource_id_to_uid = {}
    @task_id_to_uid = {}
    @version_id_to_uid = {}
    @calendar_id_to_uid = {}

    export = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      resources = @project.assignable_users
      xml.Project('xmlns' => 'http://schemas.microsoft.com/project') {
        xml.Title @project.name
        xml.ExtendedAttributes {
          xml.ExtendedAttribute {
            xml.FieldID FIELD_IDS[@settings[:redmine_status_field_name]]
            xml.FieldName @settings[:redmine_status_field_name]
            xml.Alias @settings[:redmine_status_alias]
          }
          xml.ExtendedAttribute {
            xml.FieldID FIELD_IDS[@settings[:redmine_id_field_name]]
            xml.FieldName @settings[:redmine_id_field_name]
            xml.Alias @settings[:redmine_id_alias]
          }
          xml.ExtendedAttribute {
            xml.FieldID FIELD_IDS[@settings[:tracker_field_name]]
            xml.FieldName @settings[:tracker_field_name]
            xml.Alias @settings[:tracker_alias]
          }
        }
        xml.Calendars {
          xml.Calendar {
            xml.UID @uid
            xml.Name STANDARD_CALENDAR[:name]
            xml.IsBaseCalendar 1
            xml.IsBaselineCalendar 0
            xml.BaseCalendarUID 0
            xml.Weekdays{
              STANDARD_CALENDAR['week_days'].each do |week_day|
                xml.Weekday {
                  xml.DayType week_day['day_type']
                  xml.DayWorking week_day['day_working']
                  if week_day.key?('working_times')
                    xml.WorkingTimes {
                      week_day['working_times'].each do |working_time| 
                        xml.WorkingTime {
                          xml.FromTime working_time['from_time']
                          xml.ToTime working_time['to_time']
                        }
                      end
                    }
                  end
                }
              end
            }
          }
          resources.each do |resource|
            @uid += 1
            @calendar_id_to_uid[resource.id] = @uid
            xml.Calendar {
              xml.UID @uid
              xml.Name resource.login
              xml.IsBaseCalendar 0
              xml.IsBaselineCalendar 0
              xml.BaseCalendarUID 1
            }
          end
        }
        xml.Tasks {
          xml.Task {
            xml.UID 0
            xml.ID 0
            xml.ConstraintType 0
            xml.OutlineNumber 0
            xml.OutlineLevel 0
            xml.Name @project.name
            xml.Type 1
            xml.CreateDate @project.created_on.to_s(:ms_xml)
          }

          if @export_versions
            versions = @query ? Version.where(id: @query_issues.map(&:fixed_version_id).uniq) : @project.versions
            versions.each { |version| write_version(xml, version) }
          end
          issues = (@query_issues || @project.issues.visible)
          nested_issues = determine_nesting issues, versions.try(:count)
          nested_issues.each_with_index { |issue, id| write_task(xml, issue, id) }

        }
        xml.Resources {
          xml.Resource {
            xml.UID 0
            xml.ID 0
            xml.Type 1
            xml.IsNull 0
          }
          resources.each_with_index do |resource, id|
            spent_time = TimeEntry.where(user_id: resource.id).inject(0){|sum, te| sum + te.hours }
            @uid += 1
            @resource_id_to_uid[resource.id] = @uid
            xml.Resource {
              xml.UID @uid
              xml.ID id.next
              xml.Name resource.login
              xml.Type 1
              xml.IsNull 0
              xml.MaxUnits 1.00
              xml.PeakUnits 1.00
              xml.IsEnterprise 1
              xml.CalendarUID @calendar_id_to_uid[resource.id]
              xml.ActualWork get_scorm_time(spent_time) unless spent_time.zero?
            }
          end
        }
        xml.Assignments {
          source_issues = @query ? @query_issues : @project.issues
          source_issues.select { |issue| issue.assigned_to_id? && issue.leaf? }.each do |issue|
            @uid += 1
            xml.Assignment {
              unless ignore_field?(:estimated_hours, :export) && !issue.leaf?
                time = get_scorm_time(issue.estimated_hours)
                xml.Work time
                xml.RegularWork time
                xml.RemainingWork time
              end
              xml.UID @uid
              xml.TaskUID @task_id_to_uid[issue.id]
              xml.ResourceUID @resource_id_to_uid[issue.assigned_to_id]
              xml.PercentWorkComplete issue.done_ratio unless ignore_field?(:done_ratio, :export)
              xml.Units 1
              unless issue.total_spent_hours.zero?
                xml.TimephasedData {
                  xml.Type 2
                  xml.UID @uid
                  xml.Unit 2
                  xml.Value get_scorm_time(issue.total_spent_hours)
                  xml.Start (issue.start_date || issue.created_on).to_time.to_s(:ms_xml)
                  xml.Finish ((issue.start_date || issue.created_on).to_time + (issue.total_spent_hours.to_i).hours).to_s(:ms_xml)
                }
              end
            }
          end
        }
      }
    end

    filename = "#{@project.name}-#{Time.now.strftime("%Y-%m-%d-%H-%M")}.xml"
    return export.to_xml, filename
  end

  def issue_list_mine(issues)
    # ancestors = []
    issues.each do |issue|
      # while (ancestors.any? && !issue.is_descendant_of?(ancestors.last))
      #   ancestors.pop
      # end
      issue.class.module_eval { attr_accessor :level}
      issue.level = issue.ancestors.count
      # ancestors << issue unless issue.leaf?
    end
    return issues
  end

  def determine_nesting(issues, versions_count)
    versions_count ||= 0
    nested_issues = []
    # debugger
    # leveled_tasks = issues.sort_by(&:id).group_by(&:level)
    # issue_list(issue.descendants.visible.sort_by(&:lft)) do |child, level|
    leveled = issues.sort_by(&:id)
    leveled_tasks = issue_list_mine(leveled).group_by(&:level)
    # .group_by(&:level)
    # grouped_issue_list(issues, @query, @issue_count_by_group) do |issue, level, group_name, group_count, group_totals|
    leveled_tasks.sort_by{ |key| key }.each do |level, grouped_issues|
      grouped_issues.each_with_index do |issue, index|
        outlinenumber = if issue.child?
          "#{nested_issues.detect{ |struct| struct.id == issue.parent_id }.try(:outlinenumber)}.#{leveled_tasks[level].index(issue).next}"
        else
          (leveled_tasks[level].index(issue).next + versions_count).to_s
        end
        nested_issues << ExportTask.new(issue, issue.level.next, outlinenumber)
      end
    end
    return nested_issues.sort_by!(&:outlinenumber)
  end

  def get_priority_value(priority_name)
    value = case priority_name
            when 'Minimal' then 100
            when 'Low' then 300
            when 'Normal' then 500
            when 'High' then 700
            when 'Immediate' then 900
            end
    return value
  end

  def get_scorm_time time
    return 'PT8H0M0S' if time.nil? || time.zero?
    time = time.to_s.split('.')
    hours = time.first.to_i
    minutes = time.last.to_i == 0 ? 0 : (60 * "0.#{time.last}".to_f).to_i
    return "PT#{hours}H#{minutes}M0S"
  end

  def write_task(xml, struct, id)
    @uid += 1
    @task_id_to_uid[struct.id] = @uid
    xml.Task {
      xml.UID @uid
      xml.ID id.next
      xml.Name(struct.subject)
      xml.Notes(struct.description) unless ignore_field?(:description, :export)
      xml.Active 1
      xml.IsNull 0
      xml.CreateDate struct.created_on.to_s(:ms_xml)
      xml.HyperlinkAddress issue_url(struct.issue)
      xml.Priority(ignore_field?(:priority, :export) ? 500 : get_priority_value(struct.priority.name))
      start_date = struct.issue.next_working_date(struct.start_date || struct.created_on.to_date)
      xml.Start start_date.to_time.to_s(:ms_xml)
      finish_date = if struct.due_date
                      if struct.issue.next_working_date(struct.due_date).day == start_date.day
                        start_date.next
                      else
                        struct.issue.next_working_date(struct.due_date)
                      end
                    else
                      start_date.next
                    end
      xml.Finish finish_date.to_time.to_s(:ms_xml)
      xml.ManualStart start_date.to_time.to_s(:ms_xml)
      xml.ManualFinish finish_date.to_time.to_s(:ms_xml)
      xml.EarlyStart start_date.to_time.to_s(:ms_xml)
      xml.EarlyFinish finish_date.to_time.to_s(:ms_xml)
      xml.LateStart start_date.to_time.to_s(:ms_xml)
      xml.LateFinish finish_date.to_time.to_s(:ms_xml)
      time = get_scorm_time(struct.estimated_hours)
      xml.Work time
      xml.Duration get_scorm_time(duration(start_date, finish_date)*8)
      #xml.ManualDuration time
      #xml.RemainingDuration time
      #xml.RemainingWork time
      #xml.DurationFormat 7
      xml.ActualWork get_scorm_time(struct.total_spent_hours) unless struct.total_spent_hours.zero?
      xml.Milestone 0
      xml.FixedCostAccrual 3
      xml.ConstraintType 2
      xml.ConstraintDate start_date.to_time.to_s(:ms_xml)
      xml.IgnoreResourceCalendar 0
      parent = struct.leaf? ? 0 : 1
      xml.Summary(parent)
      #xml.Critical(parent)
      xml.Rollup(parent)
      #xml.Type(parent)
      if @export_versions && struct.fixed_version_id
        xml.PredecessorLink {
          xml.PredecessorUID @version_id_to_uid[struct.fixed_version_id]
          xml.CrossProject 0
        }
      end
      if struct.relations_to_ids.any?
        struct.relations.select { |ir| ir.relation_type == 'precedes' }.each do |relation|
          xml.PredecessorLink {
            xml.PredecessorUID @task_id_to_uid[relation.issue_from_id]
            if struct.project_id == relation.issue_from.project_id
              xml.CrossProject 0
            else
              xml.CrossProject 1
              xml.CrossProjectName relation.issue_from.project.name
            end
            xml.LinkLag (relation.delay * 4800)
            xml.LagFormat 7
          }
        end
      end
      xml.ExtendedAttribute {
        xml.FieldID 188744000
        xml.Value struct.status.name
      }
      xml.ExtendedAttribute {
        xml.FieldID 188744001
        xml.Value struct.id
      }
      xml.ExtendedAttribute {
        xml.FieldID 188744002
        xml.Value struct.tracker.name
      }
      xml.WBS(struct.outlinenumber)
      xml.OutlineNumber struct.outlinenumber
      xml.OutlineLevel struct.outlinelevel
    }
  end

  def write_version(xml, version)
    xml.Task {
      @uid += 1
      @version_id_to_uid[version.id] = @uid
      xml.UID @uid
      xml.ID version.id
      xml.Name version.name
      xml.Notes version.description
      xml.CreateDate version.created_on.to_s(:ms_xml)
      if version.effective_date
        xml.Start version.effective_date.to_time.to_s(:ms_xml)
        xml.Finish version.effective_date.to_time.to_s(:ms_xml)
      end
      xml.Milestone 1
      xml.FixedCostAccrual 3
      xml.ConstraintType 4
      xml.ConstraintDate version.try(:effective_date).try(:to_time).try(:to_s, :ms_xml)
      xml.Summary 1
      xml.Critical 1
      xml.Rollup 1
      xml.Type 1
      xml.ExtendedAttribute {
        xml.FieldID 188744001
        xml.Value version.id
      }
      xml.WBS @uid
      xml.OutlineNumber @uid
      xml.OutlineLevel 1
    }
  end

  def duration(start_date, finish_date)
    duration = 0
    start_date.upto(finish_date) do |day|
      if STANDARD_WEEK_DAYS[day.cwday]['day_working'] == 1
        duration += 1
      end
    end
    duration
  end
end
