class RandomTopicSelector

  BACKFILL_SIZE = 3000
  BACKFILL_LOW_WATER_MARK = 500

  def self.backfill(category=nil)

    exclude = category.try(:topic_id)

    # don't leak private categories into the "everything" group
    user = category ? CategoryFeaturedTopic.fake_admin : nil

    options = {
      per_page: SiteSetting.category_featured_topics,
      visible: true,
      no_definitions: true
    }

    options[:except_topic_ids] = [category.topic_id] if exclude
    options[:category] = category.id if category

    query = TopicQuery.new(user, options)
    results = query.latest_results.order('RANDOM()')
                   .where(closed: false, archived: false)
                   .limit(BACKFILL_SIZE)
                   .reorder('RANDOM()')
                   .pluck(:id)

    key = cache_key(category)
    results.each do |id|
      $redis.rpush(key, id)
    end
    $redis.expire(key, 2.days)

    results
  end

  def self.next(count, category=nil)
    key = cache_key(category)

    results = []

    left = count

    while left > 0
      id = $redis.lpop key
      break unless id

      results << id.to_i
      left -= 1
    end

    backfilled = false
    if left > 0
      ids = backfill(category)
      backfilled = true
      results += ids[0...count]
      results.uniq!
      results = results[0...count]
    end

    if !backfilled && $redis.llen(key) < BACKFILL_LOW_WATER_MARK
      Scheduler::Defer.later("backfill") do
        backfill(category)
      end
    end

    results
  end

  def self.clear_cache!
    Category.select(:id).each do |c|
      $redis.del cache_key(c)
    end
    $redis.del cache_key
  end

  def self.cache_key(category=nil)
    "random_topic_cache_#{category.try(:id)}"
  end

end
