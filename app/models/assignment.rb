class Assignment < ActiveRecord::Base
  include DynamicReviewMapping

  belongs_to :course
  belongs_to :wiki_type
  # wiki_type needs to be removed. When an assignment is created, it needs to
  # be created as an instance of a subclass of the Assignment (model) class;
  # then Rails will "automatically" set the type field to the value that
  # designates an assignment of the appropriate type.
  has_many :participants, :class_name => 'AssignmentParticipant', :foreign_key => 'parent_id'
  has_many :participant_review_mappings, :class_name => 'ParticipantReviewResponseMap', :through => :participants, :source => :review_mappings
  has_many :users, :through => :participants
  has_many :due_dates
  has_many :teams, :class_name => 'AssignmentTeam', :foreign_key => 'parent_id'
  has_many :team_review_mappings, :class_name => 'TeamReviewResponseMap', :through => :teams, :source => :review_mappings
  has_many :invitations, :class_name => 'Invitation', :foreign_key => 'assignment_id'
  has_many :assignment_questionnaires, :class_name => 'AssignmentQuestionnaires', :foreign_key => 'assignment_id'
  has_many :questionnaires, :through => :assignment_questionnaires
  belongs_to  :instructor, :class_name => 'User', :foreign_key => 'instructor_id'    
  has_many :sign_up_topics, :foreign_key => 'assignment_id', :dependent => :destroy  

  validates_presence_of :name
  validates_uniqueness_of :scope => [:directory_path, :instructor_id]

  COMPLETE = "Complete"

  #  Review Strategy information.
  RS_INSTRUCTOR_SELECTED = 'Instructor-Selected'
  RS_STUDENT_SELECTED    = 'Student-Selected'
  RS_AUTO_SELECTED       = 'Auto-Selected'
  REVIEW_STRATEGIES = [RS_INSTRUCTOR_SELECTED, RS_STUDENT_SELECTED, RS_AUTO_SELECTED]

  DEFAULT_MAX_REVIEWERS = 3

  # Returns a set of topics that can be reviewed.
  # We choose the topics if one of its submissions has received the fewest reviews so far
  def candidate_topics_to_review
    return nil if sign_up_topics.empty?   # This is not a topic assignment
    
    contributor_set = Array.new(contributors)
    
    # Reject contributors that have not selected a topic, or have no submissions
    contributor_set.reject! { |contributor| signed_up_topic(contributor).nil? or !contributor.has_submissions? }
    
    # Reject contributions of topics whose deadline has passed
    contributor_set.reject! { |contributor| contributor.assignment.get_current_stage(signed_up_topic(contributor).id) == "Complete" or
                                            contributor.assignment.get_current_stage(signed_up_topic(contributor).id) == "submission" }
    # Filter the contributors with the least number of reviews
    # (using the fact that each contributor is associated with a topic)
    contributor = contributor_set.min_by { |contributor| contributor.review_mappings.count }

    min_reviews = contributor.review_mappings.count rescue 0
    contributor_set.reject! { |contributor| contributor.review_mappings.count > min_reviews + review_topic_threshold }
    
    candidate_topics = Set.new
    contributor_set.each { |contributor| candidate_topics.add(signed_up_topic(contributor)) }
    candidate_topics
  end

  def has_topics?
    @has_topics ||= !sign_up_topics.empty?
  end

  def assign_reviewer_dynamically(reviewer, topic)
    # The following method raises an exception if not successful which 
    # has to be captured by the caller (in review_mapping_controller)
    contributor = contributor_to_review(reviewer, topic)
    
    contributor.assign_reviewer(reviewer)
  end
  
  # Returns a contributor to review if available, otherwise will raise an error
  def contributor_to_review(reviewer, topic)
    raise "Please select a topic" if has_topics? and topic.nil?
    raise "This assignment does not have topics" if !has_topics? and topic
    
    # This condition might happen if the reviewer waited too much time in the
    # select topic page and other students have already selected this topic.
    # Another scenario is someone that deliberately modifies the view.
    if topic
      raise "This topic has too many reviews; please select another one." unless candidate_topics_to_review.include?(topic)
    end
    
    contributor_set = Array.new(contributors)
    work = (topic.nil?) ? 'assignment' : 'topic'

    # 1) Only consider contributors that worked on this topic; 2) remove reviewer as contributor
    # 3) remove contributors that have not submitted work yet
    contributor_set.reject! do |contributor| 
      signed_up_topic(contributor) != topic or # both will be nil for assignments with no signup sheet
        contributor.includes?(reviewer) or
        !contributor.has_submissions?
    end
    raise "There are no more submissions to review on this #{work}." if contributor_set.empty?

    # Reviewer can review each contributor only once 
    contributor_set.reject! { |contributor| contributor.reviewed_by?(reviewer) }
    raise "You have already reviewed all submissions for this #{work}." if contributor_set.empty?

    # Reduce to the contributors with the least number of reviews ("responses") received
    min_contributor = contributor_set.min_by { |a| a.responses.count }
    min_reviews = min_contributor.responses.count
    contributor_set.reject! { |contributor| contributor.responses.count > min_reviews }

    # Pick the contributor whose most recent reviewer was assigned longest ago
    if min_reviews > 0
      # Sort by last review mapping id, since it reflects the order in which reviews were assigned
      # This has a round-robin effect
      # Sorting on id assumes that ids are assigned sequentially in the db.
      # .last assumes the database returns rows in the order they were created.
      # Added unit tests to ensure these conditions are both true with the current database.
      contributor_set.sort! { |a, b| a.review_mappings.last.id <=> b.review_mappings.last.id }
  end

    # Choose a contributor at random (.sample) from the remaining contributors.
    # Actually, we SHOULD pick the contributor who was least recently picked.  But sample
    # is much simpler, and probably almost as good, given that even if the contributors are
    # picked in round-robin fashion, the reviews will not be submitted in the same order that
    # they were picked.
    return contributor_set.sample
  end

  def contributors
    @contributors ||= team_assignment ? teams : participants
  end

  def review_mappings
    @review_mappings ||= team_assignment ? team_review_mappings : participant_review_mappings
  end

  def assign_metareviewer_dynamically(metareviewer)
    # The following method raises an exception if not successful which 
    # has to be captured by the caller (in review_mapping_controller)
    response_map = response_map_to_metareview(metareviewer)
    
    response_map.assign_metareviewer(metareviewer)
  end

  # Returns a review (response) to metareview if available, otherwise will raise an error
  def response_map_to_metareview(metareviewer)
    response_map_set = Array.new(review_mappings)

    # Reject response maps without responses
    response_map_set.reject! { |response_map| !response_map.response }
    raise "There are no reviews to metareview at this time for this assignment." if response_map_set.empty?

    # Reject reviews where the metareviewer was the reviewer or the contributor
    response_map_set.reject! do |response_map| 
      (response_map.reviewee == metareviewer) or (response_map.reviewer.includes?(metareviewer))
    end
    raise "There are no more reviews to metareview for this assignment." if response_map_set.empty?

    # Metareviewer can only metareview each review once
    response_map_set.reject! { |response_map| response_map.metareviewed_by?(metareviewer) }
    raise "You have already metareviewed all reviews for this assignment." if response_map_set.empty?

    # Reduce to the response maps with the least number of metareviews received
    response_map_set.sort! { |a, b| a.metareview_response_maps.count <=> b.metareview_response_maps.count }
    min_metareviews = response_map_set.first.metareview_response_maps.count
    response_map_set.reject! { |response_map| response_map.metareview_response_maps.count > min_metareviews }

    # Reduce the response maps to the reviewers with the least number of metareviews received
    reviewers = Hash.new    # <reviewer, number of metareviews>
    response_map_set.each do |response_map|
      reviewer = response_map.reviewer
      reviewers.member?(reviewer) ? reviewers[reviewer] += 1 : reviewers[reviewer] = 1
    end
    reviewers = reviewers.sort { |a, b| a[1] <=> b[1] }
    min_metareviews = reviewers.first[1]
    reviewers.reject! { |reviewer| reviewer[1] == min_metareviews }
    response_map_set.reject! { |response_map| reviewers.member?(response_map.reviewer) }

    # Pick the response map whose most recent metareviewer was assigned longest ago
    response_map_set.sort! { |a, b| a.metareview_response_maps.count <=> b.metareview_response_maps.count }
    min_metareviews = response_map_set.first.metareview_response_maps.count
    if min_metareviews > 0
      # Sort by last metareview mapping id, since it reflects the order in which reviews were assigned
      # This has a round-robin effect
      response_map_set.sort! { |a, b| a.metareview_response_maps.last.id <=> b.metareview_response_maps.last.id }
    end

    # The first review_map is the best candidate to metareview
    return response_map_set.first
  end

  def is_using_dynamic_reviewer_assignment?
    if self.review_assignment_strategy == RS_AUTO_SELECTED or
       self.review_assignment_strategy == RS_STUDENT_SELECTED
      return true
    else
      return false
    end
  end

  def review_mappings
    if team_assignment
      TeamReviewResponseMap.find_all_by_reviewed_object_id(self.id)
    else
      ParticipantReviewResponseMap.find_all_by_reviewed_object_id(self.id)
    end
  end
  
  def metareview_mappings
     mappings = Array.new
     self.review_mappings.each{
       | map |
       mmap = MetareviewResponseMap.find_by_reviewed_object_id(map.id)
       if mmap != nil
         mappings << mmap
       end
     }
     return mappings     
  end
  
  def get_scores(questions)
    scores = Hash.new
   
    scores[:participants] = Hash.new    
    self.participants.each{
      | participant |
      scores[:participants][participant.id.to_s.to_sym] = Hash.new
      scores[:participants][participant.id.to_s.to_sym][:participant] = participant
      questionnaires.each{
        | questionnaire |
        scores[:participants][participant.id.to_s.to_sym][questionnaire.symbol] = Hash.new
        scores[:participants][participant.id.to_s.to_sym][questionnaire.symbol][:assessments] = questionnaire.get_assessments_for(participant)
        scores[:participants][participant.id.to_s.to_sym][questionnaire.symbol][:scores] = Score.compute_scores(scores[:participants][participant.id.to_s.to_sym][questionnaire.symbol][:assessments], questions[questionnaire.symbol])        
      } 
      scores[:participants][participant.id.to_s.to_sym][:total_score] = compute_total_score(scores[:participants][participant.id.to_s.to_sym])
    }        
    
    if self.team_assignment
      scores[:teams] = Hash.new
      index = 0
      self.teams.each{
        | team |
        scores[:teams][index.to_s.to_sym] = Hash.new
        scores[:teams][index.to_s.to_sym][:team] = team
        assessments = TeamReviewResponseMap.get_assessments_for(team)
        scores[:teams][index.to_s.to_sym][:scores] = Score.compute_scores(assessments, questions[:review])
        index += 1
      }
    end
    return scores
  end
  
  def compute_scores
    scores = Hash.new
    questionnaires = self.questionnaires
    
    self.participants.each{
      | participant |
      pScore = Hash.new
      pScore[:id] = participant.id
      
      
      scores << pScore
    }
  end
  
  def get_contributor(contrib_id)
    if team_assignment
      return AssignmentTeam.find(contrib_id)
    else
      return AssignmentParticipant.find(contrib_id)
    end
  end
   
  # parameterized by questionnaire
  def get_max_score_possible(questionnaire)
    max = 0
    sum_of_weights = 0
    num_questions = 0
    questionnaire.questions.each { |question| #type identifies the type of questionnaire  
      sum_of_weights += question.weight
      num_questions+=1
    }
    max = num_questions * questionnaire.max_question_score * sum_of_weights
    return max, sum_of_weights
  end
    
  def get_path
    if self.course_id == nil and self.instructor_id == nil
      raise "Path can not be created. The assignment must be associated with either a course or an instructor."
    end
    if self.wiki_type_id != 1
      raise PathError, "No path needed"
    end
    if self.course_id != nil && self.course_id > 0
       path = Course.find(self.course_id).get_path
    else
       path = RAILS_ROOT + "/pg_data/" +  FileHelper.clean_path(User.find(self.instructor_id).name) + "/"
    end         
    return path + FileHelper.clean_path(self.directory_path)      
  end 
    
  # Check whether review, metareview, etc.. is allowed
  # If topic_id is set, check for that topic only. Otherwise, check to see if there is any topic which can be reviewed(etc) now
  def check_condition(column,topic_id=nil)
    if self.staggered_deadline?
      # next_due_date - the nearest due date that hasn't passed
      if topic_id
        # next for topic
        next_due_date = TopicDeadline.find(:first,
          :conditions => ['topic_id = ? and due_at >= ?', topic_id, Time.now],
          :order => 'due_at')
      else
        # next for assignment
        next_due_date = TopicDeadline.find(:first,
          :conditions => ['assignment_id = ? and due_at >= ?', self.id, Time.now],
          :joins => {:topic => :assignment},
          :order => 'due_at')
      end
    else
      next_due_date = DueDate.find(:first, :conditions => ['assignment_id = ? and due_at >= ?', self.id, Time.now], :order => 'due_at')
    end

    if next_due_date.nil?
      return false
    end

    # command pattern - get the attribute with the name in column
    # Here, column is usually something like 'review_allowed_id'
    right_id = next_due_date.send column

    right = DeadlineRight.find(right_id)
    return (right and (right.name == "OK" or right.name == "Late"))    
  end
    
  # Determine if the next due date from now allows for submissions
  def submission_allowed(topic_id=nil)
    return (check_condition("submission_allowed_id",topic_id))
  end
  
  # Determine if the next due date from now allows for reviews or metareviews
  def review_allowed(topic_id=nil)
    return (check_condition("review_allowed_id",topic_id) or self.metareview_allowed)
  end  
  
  # Determine if the next due date from now allows for metareviews
  def metareview_allowed(topic_id=nil)
    return check_condition("metareview_allowed_id",topic_id)
  end

  def signup_allowed(topic_id=nil)
    return check_condition("signup_allowed_id",topic_id)
  end

  def drop_allowed(topic_id=nil)
    return check_condition("drop_allowed_id",topic_id)
  end

  def teammate_review_allowed(topic_id=nil)
    return check_condition("teammate_review_allowed_id",topic_id)
  end

  def survey_response_allowed(topic_id=nil)
    return check_condition("survey_response_allowed_id",topic_id)
  end


  def delete(force = nil)
    begin
      maps = ParticipantReviewResponseMap.find_all_by_reviewed_object_id(self.id)
      maps.each{|map| map.delete(force)}
    rescue
      raise "At least one review response exists for #{self.name}."
    end
    
    begin
      maps = TeamReviewResponseMap.find_all_by_reviewed_object_id(self.id)
      maps.each{|map| map.delete(force)}
    rescue
      raise "At least one review response exists for #{self.name}."
    end
    
    begin
      maps = TeammateReviewResponseMap.find_all_by_reviewed_object_id(self.id)
      maps.each{|map| map.delete(force)}
    rescue
      raise "At least one teammate review response exists for #{self.name}."
    end
    
    self.invitations.each{|invite| invite.destroy}
    self.teams.each{| team | team.delete}
    self.participants.each {|participant| participant.delete}
    self.due_dates.each{ |date| date.destroy}   
           
    # The size of an empty directory is 2
    # Delete the directory if it is empty
    begin
      directory = Dir.entries(RAILS_ROOT + "/pg_data/" + self.directory_path)
    rescue
      # directory is empty
    end
       
    if !is_wiki_assignment and !self.directory_path.empty? and !directory.nil?
      if directory.size == 2
        Dir.delete(RAILS_ROOT + "/pg_data/" + self.directory_path)
      else
        raise "Assignment directory is not empty"
      end
    end
    
    self.assignment_questionnaires.each{|aq| aq.destroy}
    
    self.destroy
  end      
  
  # Generate emails for reviewers when new content is available for review
  #ajbudlon, sept 07, 2007   
  def email(author_id) 
  
    # Get all review mappings for this assignment & author
    participant = AssignmentParticipant.find(author_id)
    if team_assignment
      author = participant.team
    else
      author = participant
    end
    
    for mapping in author.review_mappings

       # If the reviewer has requested an e-mail deliver a notification
       # that includes the assignment, and which item has been updated.
       if mapping.reviewer.user.email_on_submission
          user = mapping.reviewer.user
          Mailer.deliver_message(
            {:recipients => user.email,
             :subject => "A new submission is available for #{self.name}",
             :body => {
              :obj_name => self.name,
              :type => "submission",
              :location => get_review_number(mapping).to_s,
              :first_name => ApplicationHelper::get_user_first_name(user),
              :partial_name => "update"
             }
            }
          )
       end
    end
  end 

  # Get all review mappings for this assignment & reviewer
  # required to give reviewer location of new submission content
  # link can not be provided as it might give user ability to access data not
  # available to them.  
  #ajbudlon, sept 07, 2007      
  def get_review_number(mapping)
    reviewer_mappings = ResponseMap.find_all_by_reviewer_id(mapping.reviewer.id)
    review_num = 1
    for rm in reviewer_mappings
      if rm.reviewee.id != mapping.reviewee.id
        review_num += 1
      else
        break
      end
    end  
    return review_num
  end
 
 # It appears that this method is not used at present!
 def is_wiki_assignment
   return (self.wiki_type_id > 1)
 end
 
 #
 def self.is_submission_possible (assignment)
    # Is it possible to upload a file?
    # Check whether the directory text box is nil
    if assignment.directory_path != nil && assignment.wiki_type == 1      
      return true   
      # Is it possible to submit a URL (or a wiki page)
    elsif assignment.directory_path != nil && /(^$)|(^(http|https):\/\/[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,5}(([0-9]{1,5})?\/.*)?$)/ix.match(assignment.directory_path)
        # In this case we have to check if the directory_path starts with http / https.
        return true
    # Is it possible to submit a Google Doc?
#    removed because google doc not implemented
#    elsif assignment.wiki_type == 4 #GOOGLE_DOC
#      return true
    else
      return false
    end
 end
 
 def is_google_doc
   # This is its own method so that it can be refactored later.
   # Google Document code should never directly check the wiki_type_id
   # and should instead always call is_google_doc.
   self.wiki_type_id == 4
 end
 
#add a new participant to this assignment
#manual addition
# user_name - the user account name of the participant to add
def add_participant(user_name)
  user = User.find_by_name(user_name)
  if (user == nil) 
    raise "No user account exists with the name "+user_name+". Please <a href='"+url_for(:controller=>'users',:action=>'new')+"'>create</a> the user first."
  end
  participant = AssignmentParticipant.find_by_parent_id_and_user_id(self.id, user.id)   
  if !participant
    newpart = AssignmentParticipant.create(:parent_id => self.id, :user_id => user.id, :permission_granted => user.master_permission_granted)      
    newpart.set_handle()         
  else
    raise "The user \""+user.name+"\" is already a participant."
  end
 end
 
 def create_node()
      parent = CourseNode.find_by_node_object_id(self.course_id)      
      node = AssignmentNode.create(:node_object_id => self.id)
      if parent != nil
        node.parent_id = parent.id       
      end
      node.save   
 end


  def get_current_stage(topic_id=nil)
    if self.staggered_deadline?
      if topic_id.nil?
        return "Unknown"
      end
    end
    due_date = find_current_stage(topic_id)
    if due_date == nil or due_date == COMPLETE
      return COMPLETE
    else
      return DeadlineType.find(due_date.deadline_type_id).name
    end
  end


  def get_stage_deadline(topic_id=nil)
     if self.staggered_deadline?
        if topic_id.nil?
          return "Unknown"
        end
     end

    due_date = find_current_stage(topic_id)
    if due_date == nil or due_date == COMPLETE
      return due_date
    else
      return due_date.due_at.to_s
    end
  end

   def get_review_rounds
    due_dates = DueDate.find_all_by_assignment_id(self.id)
    rounds = 0
    for i in (0 .. due_dates.length-1)
      deadline_type = DeadlineType.find(due_dates[i].deadline_type_id)
      if deadline_type.name == "review" || deadline_type.name == "rereview"
        rounds = rounds + 1
      end
    end
    rounds
  end

  
 def find_current_stage(topic_id=nil)
    if self.staggered_deadline?
      due_dates = TopicDeadline.find(:all,
                   :conditions => ["topic_id = ?", topic_id],
                   :order => "due_at DESC")
    else
      due_dates = DueDate.find(:all,
                   :conditions => ["assignment_id = ?", self.id],
                   :order => "due_at DESC")
    end


    if due_dates != nil and due_dates.size > 0
      if Time.now > due_dates[0].due_at
        return COMPLETE
      else
        i = 0
        for due_date in due_dates
          if Time.now < due_date.due_at and
             (due_dates[i+1] == nil or Time.now > due_dates[i+1].due_at)
            return due_date
          end
          i = i + 1
        end
      end
    end
  end  
  
 def assign_reviewers(mapping_strategy)  
      if (team_assignment)      
          #defined in DynamicReviewMapping module
          assign_reviewers_for_team(mapping_strategy)
      else          
          #defined in DynamicReviewMapping module
          assign_individual_reviewer(mapping_strategy) 
      end  
  end  

#this is for staggered deadline assignments or assignments with signup sheet
def assign_reviewers_staggered(num_reviews,num_review_of_reviews)
    #defined in DynamicReviewMapping module
    message = assign_reviewers_automatically(num_reviews,num_review_of_reviews)
    return message
end

  def get_current_due_date()
    #puts "~~~~~~~~~~Enter get_current_due_date()\n"
    due_date = self.find_current_stage()
    if due_date == nil or due_date == COMPLETE
      return COMPLETE
    else
      return due_date
    end
    
  end
  
  def get_next_due_date()
    #puts "~~~~~~~~~~Enter get_next_due_date()\n"
    due_date = self.find_next_stage()
    
    if due_date == nil or due_date == COMPLETE
      return nil
    else
      return due_date
    end
    
  end
  
  def find_next_stage()
    #puts "~~~~~~~~~~Enter find_next_stage()\n"
    due_dates = DueDate.find(:all, 
                 :conditions => ["assignment_id = ?", self.id],
                 :order => "due_at DESC")
                 
    if due_dates != nil and due_dates.size > 0
      if Time.now > due_dates[0].due_at
        return COMPLETE
      else
        i = 0
        for due_date in due_dates
          if Time.now < due_date.due_at and
             (due_dates[i+1] == nil or Time.now > due_dates[i+1].due_at)
             if (i > 0)
               return due_dates[i-1]
             else
               return nil  
             end
          end
          i = i + 1
        end
        
        return nil
      end
    end
  end

  # Compute total score for this assignment by summing the scores given on all questionnaires.
  # Only scores passed in are included in this sum.
  def compute_total_score(scores)
    total = 0
    self.questionnaires.each do |questionnaire|
      total += questionnaire.get_weighted_score(self, scores)
    end
    return total
  end
  
  # Checks whether there are duplicate assignments of the same name by the same instructor.
  # If the assignments are assigned to courses, it's OK to have duplicate names in different
  # courses.
  def duplicate_name?
    if course
      Assignment.find(:all, :conditions => ['course_id = ? and instructor_id = ? and name = ?', 
        course_id, instructor_id, name]).count > 1
    else
      Assignment.find(:all, :conditions => ['instructor_id = ? and name = ?', 
        instructor_id, name]).count > 1
    end
  end
  
    def signed_up_topic(contributor)
      # The purpose is to return the topic that the contributor has signed up to do for this assignment.
      # Returns a record from the sign_up_topic table that gives the topic_id for which the contributor has signed up
      # Look for the topic_id where the creator_id equals the contributor id (contributor is a team or a participant)
      contributors_topic = SignedUpUser.find_by_creator_id(contributor.id)
      if !contributors_topic.nil?
        contributors_signup_topic = SignUpTopic.find_by_id(contributors_topic.topic_id)
        #returns the topic
        return contributors_signup_topic
      end
  end
end
  
