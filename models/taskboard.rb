#!/usr/bin/env ruby

module Dirt
  class Taskboard 
    def initialize(spec)
      @spec = spec
    end

    def grp_seq
      @grp_seq = @spec['group_sequence']
      return @grp_seq
    end

    def lcm_col
      return @lcm_col unless @lcm_col.nil?
      @lcm_col = 1
      span.each do |s|
        @lcm_col = @lcm_col.lcm(s.to_i)
      end
      return @lcm_col
    end

    def rowspan
      return @rowspan unless @rowspan.nil?
      grp_seq = @spec['group_sequence']
      @rowspan = Array.new()
      grp_seq.each_index do |row|
        @rowspan[row] = 1 
        grp_seq[row].each_index do |col|
          if grp_seq[row][col].length > 1
            @rowspan[row] = 2
          end
        end        
      end
      return @rowspan
    end

    def span
      return @span unless @span.nil?
      grp_seq = @spec['group_sequence']
      @span = Array.new()
      grp_seq.each_index do |row|
        @span << grp_seq[row].length
        grp_seq[row].each_index do |col|
          if grp_seq[row][col].length > 1
            @span[row]+= grp_seq[row][col][1].length-1
          end
        end        
      end
      return @span
    end

    def shorten(str)
      max_length = 50
      if str.length > max_length
        # str.insert(14,"- ") if str.index(' ')>14 || str.index(' ')<7 
        return str[0..max_length] << "..."
      else
        return str
      end
    end

    def classify(time)
      case Date.today - time.to_date
      when 0..7
        return "this-week"
      when 8..30
        return "this-month"
      else
        return "old"
      end
    end

    def lanes
      return ['new', 'open', 'stalled', 'resolved']
    end

    def lane_column
      return 'Status'
    end

    def streams
      return @streams unless @streams.nil?




      queues = @spec['queues']
      raise "Need a 'queues' parameter to render this macro" if queues.nil?

      # TODO:
      # Convert this subselect into a join -- may be faster
   
      parent_tickets = Dirt::RT_DB[:Links]
                        .select(:LocalTarget)
                        .where(:Type => 'MemberOf')

      @streams = Dirt::RT_DB[:expanded_tickets]
                  .select(:expanded_tickets__id, 
                    :expanded_tickets__Subject, 
                    :expanded_tickets__Owner, 
                    :expanded_tickets__LastUpdated, 
                    :expanded_tickets__Created)
                  .join(:Links, :expanded_tickets__id => :Links__LocalTarget, :Links__Type => 'MemberOf' )
                  .where(:Queue => queues)
                  .exclude(:Status => ['resolved','deleted'])
                  .distinct
                  .order_by(:expanded_tickets__Subject)
                  .all

      return @streams
    end 

    def stream_ids
      return @stream_ids unless @stream_ids.nil?

      @stream_ids = streams.collect{|stream| stream[:id]}

      return @stream_ids
    end

    def stream_members(stream_id)
      if stream_id == :all 
        stream_id = stream_ids
      end

      return Dirt::RT_DB[:Links]
              .select(:LocalBase)
              .where(:LocalTarget => stream_id, :Type => 'MemberOf')
    end

    def cards()
      return @cards unless @cards.nil?

      # Select cards from RT 
      # Select cards from dirt
      # merge both

      # Note: if both are mysql databases linked server can be created and the two queries can be combined

      raise "Need a 'queues' parameter to render this macro" if @spec['queues'].nil?
      queues = [*@spec['queues']]

      raise "Need a 'resolved_after' parameter to render this macro" if @spec['resolved_after'].nil?
      resolved_after = @spec['resolved_after']

      first_date = Chronic.parse(resolved_after).strftime('%Y-%m-%d')
      last_date = Chronic.parse("Tomorrow").strftime('%Y-%m-%d')

      sql = "SELECT 
                et.id AS id,
                et.Subject AS Subject,
                et.Owner AS Owner,
                et.LastUpdated AS LastUpdated,
                et.Created AS Created,
                et.#{lane_column()} AS #{lane_column},
                l.LocalTarget AS Parent 
            FROM expanded_tickets et
            LEFT JOIN Links l ON et.id = l.LocalBase AND l.Type = 'MemberOf'
            WHERE et.#{lane_column()} IN('#{lanes.join("', '")}')
              AND ((Resolved BETWEEN '#{first_date}' AND '#{last_date}') OR Status <> 'resolved')"

      if stream_ids.empty?
        sql <<  "AND et.Queue IN('#{queues.join("', '")}')"
      else
        sql <<  "AND (l.LocalTarget IN(#{stream_ids.join(', ')}) 
                    OR et.Queue IN('#{queues.join("', '")}'))"
      end
      sql << " ORDER BY id"

      ds = Dirt::RT_DB[sql]

      raw_cards = ds.all

      card_ids = Array.new()
      card_list = ""

      # done with retreiving cards

      @cards = raw_cards.collect do |ticket|
        card_ids.push(ticket[:id])
        ticket[:short_subject] = shorten(ticket[:Subject])
        ticket[:age_class] = classify(ticket[:LastUpdated])
        ticket[:origin] = origin(ticket[:id])
        ticket
      end

      # find all the statuses for the current project
      # have the id's of the cards, we can get the kanban status from dirt db
      # sql = "SELECT * FROM `status_tickets` AS `ts` LEFT JOIN `statuses` AS `s` ON `ts`.`status_id`=`s`.`id` WHERE `ticket_id` in (#{card_list})"
      # Have find how to do the above sql query using Dirt::DIRT_DB


      ticket_status = Dirt::StatusTicket.where(:ticket_id => card_ids).left_join(:statuses, :id => :status_id).where(:project_id => @spec[:project_id]).order(:ticket_id).all

      if ticket_status.length != @cards.length
        @unclassified_present = true
      else
        @unclassified_present = false
      end

      i = 0
      ticket_status.each do |value|
        while (@cards[i][:id] < value[:ticket_id]) do
          i += 1
        end
        if @cards[i][:id] == value[:ticket_id]
          @cards[i].merge!({:status_id => value[:status_id], :status_name => value[:status_name], :project_id => value[:project_id]})
        end
      end
      return @cards
    end

    def origin(id)
      "#{Dirt::CONFIG[:rt_url]}/Ticket/Display.html?id=#{id}"
    end

    def unclassified_present
      return @unclassified_present
    end
    
    def getcardsfor(kanban_status)
      kanban_status = kanban_status.to_s.downcase
      @cards.select do |card|
        (card[:status_name].to_s.downcase == kanban_status)
      end
    end
   
    def getunclassified
      @cards.select do |card|
        ( ( no_kanban_status? card ) && (card[:Status] != "resolved"))
      end
    end

    def no_kanban_status?(card)
      ((!defined? card[:status_name]) || (card[:status_name]).nil? || card[:status_name] == "")
    end

    def statuses
      return @statuses unless @statuses.nil?
      @statuses = Dirt::Status.where(:project_id => @spec[:project_id]).all
    end

    def getlimitfor(specname)
      statuses
      @statuses.each do |status|
        if status[:status_name].to_s.downcase == specname.to_s.downcase
          return status[:max_tickets].to_i
        end
      end
      return 0
    end
  end

end