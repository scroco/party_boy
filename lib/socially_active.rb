module Socially
	module Active
		
		class IdentityTheftError < StandardError; end
		class StalkerError < StandardError; end
		
		def self.included(klazz)
			klazz.extend(Socially::Active::ClassMethods)
			klazz.class_eval do 
				include Socially::Active::RelateableInstanceMethods
			end
		end
		
		module ClassMethods
			
			def acts_as_followable
				with_options :class_name => 'Relationship', :dependent => :destroy do |klazz|
				 klazz.has_many :followings, :as => :requestee
				 klazz.has_many :follows, :as => :requestor
				end
				
				include Socially::Active::FollowableInstanceMethods
			end
			
			def acts_as_friend
				with_options :class_name => 'Relationship', :dependent => :destroy do |klazz|
					klazz.has_many :outgoing_friendships, :as => :requestor, :include => :requestee
					klazz.has_many :incoming_friendships, :as => :requestee, :include => :requestor
				end
				
				include Socially::Active::RelateableInstanceMethods
				include Socially::Active::FriendlyInstanceMethods
			end
			
		end
		
		
		module RelateableInstanceMethods
		
		private
			
			# should be able to pass a class, string, or object and get back the super-most class (before activerecord)
			def super_class_name(obj = self)
				obj = (obj.class == Class && obj || obj.class == String && obj.constantize || obj.class)
				if obj.superclass != ActiveRecord::Base
					super_class_name(obj.superclass)
				else
					obj.name
				end
			end
			
			def super_class_names(obj = self)
				puts obj
				if obj.nil?
					return nil
				end
				obj = (obj.class == Class && obj || obj.class == String && obj.constantize || obj.class)
				if obj.superclass != ActiveRecord::Base
					[obj.name, super_class_names(obj.superclass)].flatten
				else
					[obj.name]
				end
			end
			
			def get_relationship_to(requestee)
				requestee && Relationship.unblocked.find(:first, :conditions => ['requestor_id = ? and requestor_type = ? and requestee_id = ? and requestee_type = ?', self.id, super_class_name, requestee.id, super_class_name(requestee)]) || nil
			end
			
			def get_relationship_from(requestor)
				requestor && Relationship.unblocked.find(:first, :conditions => ['requestor_id = ? and requestor_type = ? and requestee_id = ? and requestee_type = ?', requestor.id, super_class_name(requestor), self.id, super_class_name]) || nil
			end
			
		end
		
		module FollowableInstanceMethods
		
			def following?(something)
				!!(something && Relationship.unblocked.count(:conditions => ['requestor_id = ? and requestor_type = ? and requestee_id = ? and requestee_type = ?', self.id, super_class_name, something.id, super_class_name(something)]) > 0)
			end
			
			def followed_by?(something)
				!!(something && Relationship.unblocked.count(:conditions => ['requestor_id = ? and requestor_type = ? and requestee_id = ? and requestee_type = ?', something.id, super_class_name(something), self.id, super_class_name]) > 0)
			end
			
			def follow(something)
				if blocked_by?(something)
					raise(Socially::Active::StalkerError, "#{super_class_name} #{self.id} has been blocked by #{super_class_name(something)} #{something.id} but is trying to follow them")
				else
					Relationship.create(:requestor => self, :requestee => something, :restricted => false) if !(blocked_by?(something) || following?(something))
				end
			end
			
			def blocked_by?(something)
				!!(something && Relationship.blocked.count(:conditions => ['requestor_id = ? and requestor_type = ? and requestee_id = ? and requestee_type = ?', self.id, super_class_name, something.id, super_class_name(something)]) > 0)
			end
			
			def unfollow(something)
				(rel = get_relationship_to(something)) && rel.destroy
			end
			
			def block(something)
				(rel = (get_relationship_from(something) || get_relationship_to(something))) && rel.update_attribute(:restricted, true)
			end
			
			def follower_count(type = nil)
				followings.unblocked.from_type(type).size
			end
			
			def following_count(type = nil)
				follows.unblocked.to_type(type).size
			end
			
			def followers(type = nil)
				type = [type].compact.flatten
				super_class = type.last
				exact_class = type.first
				results = relationships_from(super_class)
				if super_class != exact_class
					results.collect{|r| r.requestor.class.name == exact_class && r.requestor || nil}.compact
				else
					results.collect{|r| r.requestor}
				end
					
			end
			
			def following(type = nil)
				type = [type].flatten.compact	
				super_class = type.last
				exact_class = type.first
				results = relationships_to(super_class)
				if super_class != exact_class
					results.collect{|r| r.requestee.class.name == exact_class && r.requestee || nil}.compact
				else
					results.collect{|r| r.requestee}
				end
			end
			
			def extended_network(type = nil)
				following.collect{|f| f.methods.include?('following') && f.following(type) || []}.flatten.uniq
			end
			
			def method_missing(method, *args)
				case method.id2name
				when /^(.+)ss_followers$/
					# this is for the rare case of a class name ending in ss, like 'business'; 'business'.classify => 'Busines'
					followers(super_class_names("#{$1.classify}ss"))
				when /^(.+)s_followers$/, /^(.+)_followers$/
					followers(super_class_names($1.classify))
				when /^following_(.+)$/
					following(super_class_names($1.classify))
				else
					super
				end
			end
			
		private
			
			def relationships_to(type)
				self.follows.unblocked.to_type(type).all(:include => [:requestee])
			end
			
			def relationships_from(type)
				self.followings.unblocked.from_type(type).all(:include => [:requestor])
			end
			
		end
		
		module FriendlyInstanceMethods
			
			def friends
				(outgoing_friendships.accepted + incoming_friendships.accepted).collect{|r| [r.requestor, r.requestee]}.flatten.uniq - [self]
			end
			
			def extended_network
				friends.collect{|f| f.methods.include?('friends') && f.friends || []}.flatten.uniq - [self]
			end
			
			def outgoing_friend_requests
				self.outgoing_friendships.unaccepted.all
			end
			
			def incoming_friend_requests
				self.incoming_friendships.unaccepted.all
			end
			
			def is_friends_with?(something)
				arr = something && [self.id, super_class_name, super_class_name(something), something.id]
				arr && Relationship.accepted.count(:conditions => [(['(requestor_id = ? AND requestor_type = ? AND requestee_type = ? AND requestee_id = ?)']*2).join(' OR '), arr, arr.reverse].flatten) > 0
			end
			
			def pending?(something)
				arr = something && [self.id, super_class_name, super_class_name(something), something.id]
				arr && Relationship.unaccepted.count(:conditions => [(['(requestor_id = ? AND requestor_type = ? AND requestee_type = ? AND requestee_id = ?)']*2).join(' OR '), arr, arr.reverse].flatten) > 0
			end
			
			def friend_count
				arr = [self.id, super_class_name]
				Relationship.accepted.count(:conditions => ['(requestor_id = ? AND requestor_type = ?) OR (requestee_id = ? and requestee_type = ?)', arr, arr].flatten)
			end
			
			def request_friendship(friendship_or_something)
				rel = relationship_from(friendship_or_something)
				rel.nil? && Relationship.create(:requestor => self, :requestee => friendship_or_something, :restricted => true) || rel.update_attributes(:restricted => false)
			end
			
			def deny_friendship(friendship_or_something)
				(rel = relationship_from(friendship_or_something)) && rel.destroy
			end
			
			alias_method :reject_friendship, :deny_friendship
			alias_method :accept_friendship, :request_friendship
			
		private
		
			def relationship_from(friendship_or_something)
				if friendship_or_something && friendship_or_something.class == Relationship
					raise(Socially::Active::IdentityTheftError, "#{self.class.name} with id of #{self.id} tried to access Relationship #{friendship_or_something.id}") if 	!(friendship_or_something.requestor == self || friendship_or_something.requestee == self)
					friendship_or_something
				else
					arr = friendship_or_something && [self.id, super_class_name, super_class_name(friendship_or_something), friendship_or_something.id]
					arr && Relationship.find(:first, :conditions => [(['(requestor_id = ? AND requestor_type = ? AND requestee_type = ? AND requestee_id = ?)']*2).join(' OR '), arr, arr.reverse].flatten) || nil
				end
			end	
		end
	end
end